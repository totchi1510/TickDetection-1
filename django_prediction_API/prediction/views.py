from django.conf import settings
from django.http import JsonResponse
from django.utils.decorators import method_decorator
from django.views.decorators.csrf import csrf_exempt
from inference_sdk import InferenceHTTPClient
from rest_framework.views import APIView
import tempfile

# === Roboflow configuration ===
ROBOFLOW_API_URL = getattr(settings, "ROBOFLOW_API_URL", "https://serverless.roboflow.com")
ROBOFLOW_API_KEY = getattr(settings, "ROBOFLOW_API_KEY", None)
ROBOFLOW_WORKSPACE = getattr(settings, "ROBOFLOW_WORKSPACE", "yuto-i74h0")
ROBOFLOW_WORKFLOW_ID = getattr(settings, "ROBOFLOW_WORKFLOW_ID", "detect-and-classify-3")

if not ROBOFLOW_API_KEY:
    raise RuntimeError("ROBOFLOW_API_KEY is not configured. Set it in settings or environment.")

client = InferenceHTTPClient(
    api_url=ROBOFLOW_API_URL,
    api_key=ROBOFLOW_API_KEY,
)


def _iter_workflow_outputs(result):
    """Normalise Roboflow workflow response to an iterable of output dicts."""
    if isinstance(result, list):
        return result
    if isinstance(result, dict):
        return result.get("results") or []
    return []


def _extract_top_label(result):
    """Attempt to pull the primary class label out of the workflow response."""
    for output in _iter_workflow_outputs(result):
        predictions = output.get("predictions") or []
        if not predictions:
            continue
        top_prediction = predictions[0]
        if isinstance(top_prediction, dict):
            # classification workflows typically expose `class` or `label`
            label = top_prediction.get("class") or top_prediction.get("label")
            if label:
                return label
    return None


def _extract_output_image(result):
    """Retrieve the first available base64 encoded output image, if present."""
    for output in _iter_workflow_outputs(result):
        encoded = output.get("output_image")
        if encoded:
            return encoded
    return None


@method_decorator(csrf_exempt, name='dispatch')
class PredictView(APIView):
    def post(self, request):
        try:
            uploaded_file = request.FILES.get("file")
            if not uploaded_file:
                return JsonResponse({"error": "No file supplied"}, status=400)

            # Persist the upload to a temporary file so the SDK can read it.
            with tempfile.NamedTemporaryFile(suffix=".jpg") as tmp:
                for chunk in uploaded_file.chunks():
                    tmp.write(chunk)
                tmp.flush()

                result = client.run_workflow(
                    workspace_name=ROBOFLOW_WORKSPACE,
                    workflow_id=ROBOFLOW_WORKFLOW_ID,
                    images={"image": tmp.name},
                    use_cache=True,
                )

            pred_label = _extract_top_label(result) or "Unknown"
            output_image = _extract_output_image(result)
            response_payload = {
                "prediction": pred_label,
                "output_image": output_image,
                "raw_result": result,
            }
            return JsonResponse(response_payload)

        except Exception as exc:
            return JsonResponse({"error": str(exc)}, status=400)

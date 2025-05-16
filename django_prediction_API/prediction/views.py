from rest_framework.views import APIView
from django.utils.decorators import method_decorator
from django.views.decorators.csrf import csrf_exempt
from PIL import Image
import torch
import torch.nn.functional as F
from torchvision import transforms
from django.conf import settings
import os
from torchvision.models import mobilenet_v2
import torch.nn as nn
from django.http import JsonResponse

# Create your views here.

LABELS = ['Amblyomma(Unfed)', 'Amblyomma(Blood-fed)', 'Haemaphysails', 'Ixodes']
MODEL_PATH = os.path.join(settings.BASE_DIR, 'prediction', 'mobilenet_v2_weights.pth')

# === define and load Model ===
NUM_CLASSES = 4
model = mobilenet_v2(weights=None)
model.classifier[1] = nn.Linear(model.last_channel, 4)
model.load_state_dict(torch.load(MODEL_PATH, map_location="cpu"))
model.eval()

# === preprocess ===
preprocess = transforms.Compose([
    transforms.Resize((224, 224)),
    transforms.ToTensor(),
    transforms.Normalize([0.485, 0.456, 0.406],
                         [0.229, 0.224, 0.225]),
])

@method_decorator(csrf_exempt, name='dispatch')
class PredictView(APIView):
    def post(self, request):
        try:
            uploaded_file = request.FILES.get('file')
            if uploaded_file:
                image = Image.open(uploaded_file).convert("RGB")
                input_tensor = preprocess(image).unsqueeze(0)

                with torch.no_grad():
                    output = model(input_tensor)
                    probs = F.softmax(output, dim=1)
                    pred_class = torch.argmax(probs, dim=1).item()

                pred_label = LABELS[pred_class]
                return JsonResponse({
                    "prediction": pred_label,
                })

            else:
                return JsonResponse({
                    "prediction": 'Error',
                })

        except Exception as e:
            return JsonResponse({"error": str(e)}, status=400)
    
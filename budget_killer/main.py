import base64
import json
import logging
import os
import sys

from google.cloud import run_v2
from google.iam.v1 import iam_policy_pb2

# Logging to stdout so Cloud Run / Functions Gen2 captures it reliably
logging.basicConfig(stream=sys.stdout, level=logging.INFO,
                    format="%(levelname)s %(message)s")
logger = logging.getLogger(__name__)

STOP_THRESHOLD = float(os.environ.get("STOP_THRESHOLD", "1.0"))
PROJECT_ID = os.environ["PROJECT_ID"]
REGION = os.environ["REGION"]
SERVICE_NAME = os.environ["SERVICE_NAME"]
PUBLIC_MEMBER = "allUsers"
INVOKER_ROLE = "roles/run.invoker"


def handle_budget_alert(event, context):
    """Remove public invoker access from the Cloud Run service when budget exceeded.

    Removing allUsers from roles/run.invoker means any unauthenticated request
    will return 403. Cloud Run does not spin up instances for rejected requests,
    so compute billing stops immediately.
    """
    if "data" not in event:
        logger.warning("No 'data' in event; skipping")
        return

    notif = json.loads(base64.b64decode(event["data"]).decode("utf-8"))
    threshold = notif.get("alertThresholdExceeded")
    cost = notif.get("costAmount")
    budget = notif.get("budgetAmount")
    currency = notif.get("currencyCode", "")

    logger.info("Budget alert threshold=%s cost=%s %s budget=%s",
                threshold, cost, currency, budget)

    if threshold is None or threshold < STOP_THRESHOLD:
        logger.info("Below stop threshold %s; no action", STOP_THRESHOLD)
        return

    client = run_v2.ServicesClient()
    resource = f"projects/{PROJECT_ID}/locations/{REGION}/services/{SERVICE_NAME}"

    policy = client.get_iam_policy(request=iam_policy_pb2.GetIamPolicyRequest(resource=resource))

    modified = False
    for binding in policy.bindings:
        if binding.role == INVOKER_ROLE and PUBLIC_MEMBER in binding.members:
            binding.members.remove(PUBLIC_MEMBER)
            modified = True
            logger.info("Removed %s from %s", PUBLIC_MEMBER, INVOKER_ROLE)
            break

    if not modified:
        logger.info("Service %s already non-public; no action", SERVICE_NAME)
        return

    client.set_iam_policy(request=iam_policy_pb2.SetIamPolicyRequest(resource=resource, policy=policy))
    logger.warning("STOPPED %s: removed %s invoker access (budget %s%% exceeded)",
                   SERVICE_NAME, PUBLIC_MEMBER, int(threshold * 100))

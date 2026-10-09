import json
import os
import time

import boto3

ddb = boto3.resource("dynamodb")
users = ddb.Table(os.environ["USERS_TABLE"])
survey = ddb.Table(os.environ["SURVEY_TABLE"])

# Edit plans / tariff / facilities here (or move to a DynamoDB table later)
INFO = {
    "hall": "Grand Banquet Hall (opening soon)",
    "plans": [
        {"name": "Silver", "capacity": 150, "price_per_plate": 650,  "hall_rent": 40000},
        {"name": "Gold",   "capacity": 300, "price_per_plate": 900,  "hall_rent": 75000},
        {"name": "Platinum", "capacity": 600, "price_per_plate": 1300, "hall_rent": 150000},
    ],
    "facilities": ["Air-conditioned hall", "Bridal suite", "Parking (100 cars)",
                   "In-house catering", "Stage & DJ", "Power backup", "Decor services"],
}

CORS = {"Content-Type": "application/json"}


def resp(code, body):
    return {"statusCode": code, "headers": CORS, "body": json.dumps(body)}


def handler(event, context):
    claims = event["requestContext"]["authorizer"]["jwt"]["claims"]
    uid = claims["sub"]
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    route = event["routeKey"]

    # Store / refresh user details on every call (created_at set once)
    users.update_item(
        Key={"user_id": uid},
        UpdateExpression=("SET email=:e, #n=:n, phone=:p, last_login=:t, "
                          "created_at=if_not_exists(created_at,:t)"),
        ExpressionAttributeNames={"#n": "name"},
        ExpressionAttributeValues={
            ":e": claims.get("email", ""), ":n": claims.get("name", ""),
            ":p": claims.get("phone_number", ""), ":t": now,
        },
    )

    if route == "GET /info":
        return resp(200, INFO)

    if route == "GET /me":
        return resp(200, users.get_item(Key={"user_id": uid}).get("Item", {}))

    if route == "POST /survey":
        try:
            data = json.loads(event.get("body") or "{}")
        except json.JSONDecodeError:
            return resp(400, {"error": "invalid JSON"})
        allowed = ["event_type", "expected_guests", "budget_range",
                   "preferred_month", "preferred_plan", "comments"]
        answers = {k: str(data.get(k, ""))[:1000] for k in allowed}
        if not answers["event_type"] or not answers["expected_guests"]:
            return resp(400, {"error": "event_type and expected_guests are required"})
        survey.put_item(Item={"user_id": uid, "submitted_at": now,
                              "email": claims.get("email", ""), **answers})
        return resp(200, {"message": "Thank you! Survey saved."})

    return resp(404, {"error": "not found"})

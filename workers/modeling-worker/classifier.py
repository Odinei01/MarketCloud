"""
Campaign Role Classifier — deterministic (no ML).
Rules match spec section 14.2 exactly.
"""
from dataclasses import dataclass
from typing import Optional


@dataclass
class CampaignMetrics:
    campaign_id: str
    campaign_name: str
    spend: float
    direct_conversions: int
    assisted_conversions: int
    direct_sales: float
    assisted_sales: float
    assist_rate: float          # assisted_conversions / (direct + assisted)
    first_touch_rate: float
    last_touch_rate: float
    path_presence_rate: float


@dataclass
class ClassificationResult:
    campaign_id: str
    campaign_name: str
    role: str                   # DISCOVERY | CONVERSION | ASSISTED_CONVERSION | WASTE | REMARKETING | UNKNOWN
    assist_score: float
    conversion_score: float
    waste_score: float
    remarketing_score: float
    overall_score: float
    recommended_action: str
    confidence: float
    evidence: dict


TARGET_ROAS = 4.0
MIN_CONVERSIONS = 1
MIN_SPEND = 50.0


def _normalize(value: float, min_v: float = 0.0, max_v: float = 1.0) -> float:
    if max_v == min_v:
        return 0.0
    return max(0.0, min(1.0, (value - min_v) / (max_v - min_v)))


def compute_assist_score(m: CampaignMetrics) -> float:
    return (
        _normalize(m.assist_rate, 0, 1.0) * 0.40
        + _normalize(m.assisted_sales, 0, 5000) * 0.30
        + _normalize(m.path_presence_rate, 0, 1.0) * 0.20
        + _normalize(m.first_touch_rate, 0, 1.0) * 0.10
    )


def compute_conversion_score(m: CampaignMetrics, roas: float) -> float:
    conv_rate = m.direct_conversions / max(1, m.direct_conversions + m.assisted_conversions)
    return (
        _normalize(roas, 0, 10) * 0.35
        + _normalize(conv_rate, 0, 1) * 0.25
        + _normalize(m.last_touch_rate, 0, 1) * 0.20
        + _normalize(m.direct_sales, 0, 10000) * 0.20
    )


def compute_waste_score(m: CampaignMetrics) -> float:
    no_conv = 1.0 if (m.direct_conversions == 0 and m.assisted_conversions == 0) else 0.0
    spend_ratio = _normalize(m.spend, 0, 2000)
    return (
        no_conv * spend_ratio * 0.40
        + (1 - _normalize(m.direct_conversions + m.assisted_conversions, 0, 20)) * 0.25
        + (1 - _normalize(m.assist_rate, 0, 1)) * 0.20
        + 0.15 * no_conv
    )


def classify(m: CampaignMetrics, target_roas: float = TARGET_ROAS) -> ClassificationResult:
    roas = m.direct_sales / max(1, m.spend)
    assist = compute_assist_score(m)
    conversion = compute_conversion_score(m, roas)
    waste = compute_waste_score(m)

    # CONVERSION
    if (roas >= target_roas and m.direct_conversions >= MIN_CONVERSIONS and m.last_touch_rate >= 0.50):
        role = "CONVERSION"
        action = "INCREASE_BUDGET"
        confidence = min(0.95, 0.70 + conversion * 0.25)
        overall = round(conversion * 100)

    # ASSISTED_CONVERSION
    elif (m.assist_rate >= 0.30 and m.assisted_sales > m.direct_sales and m.path_presence_rate >= 0.25):
        role = "ASSISTED_CONVERSION"
        action = "DO_NOT_PAUSE"
        confidence = min(0.92, 0.65 + assist * 0.27)
        overall = round(assist * 90)

    # DISCOVERY
    elif (roas < target_roas and m.assist_rate >= 0.25 and m.first_touch_rate >= 0.35):
        role = "DISCOVERY"
        action = "DO_NOT_PAUSE"
        confidence = min(0.88, 0.60 + assist * 0.28)
        overall = round(assist * 80)

    # REMARKETING
    elif (m.assist_rate > 0.15 and m.direct_conversions > 0 and m.spend > 0):
        role = "REMARKETING"
        action = "CREATE_AUDIENCE"
        confidence = 0.72
        overall = 65

    # WASTE
    elif (m.spend >= MIN_SPEND and m.direct_conversions == 0 and m.assisted_conversions == 0):
        role = "WASTE"
        action = "DECREASE_BID"
        confidence = min(0.95, 0.65 + waste * 0.30)
        overall = round((1 - waste) * 40)

    else:
        role = "UNKNOWN"
        action = "REVIEW_TARGET_EXCLUSION"
        confidence = 0.40
        overall = 50

    remarketing = _normalize(m.assist_rate * m.spend, 0, 500) * 0.5 + conversion * 0.3

    return ClassificationResult(
        campaign_id=m.campaign_id,
        campaign_name=m.campaign_name,
        role=role,
        assist_score=round(assist, 3),
        conversion_score=round(conversion, 3),
        waste_score=round(waste, 3),
        remarketing_score=round(remarketing, 3),
        overall_score=max(0, min(100, overall)),
        recommended_action=action,
        confidence=round(confidence, 3),
        evidence={
            "roas": round(roas, 2),
            "assist_rate": round(m.assist_rate, 3),
            "first_touch_rate": round(m.first_touch_rate, 3),
            "last_touch_rate": round(m.last_touch_rate, 3),
            "direct_conversions": m.direct_conversions,
            "assisted_conversions": m.assisted_conversions,
            "spend": round(m.spend, 2),
        },
    )

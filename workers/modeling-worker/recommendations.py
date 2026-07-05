"""
Recommendation generator — spec section 17.
"""
import json
from dataclasses import dataclass
from classifier import ClassificationResult


@dataclass
class Recommendation:
    target_type: str
    target_id: str
    target_name: str
    action_type: str
    current_value: dict
    recommended_value: dict
    impact_estimate: dict
    reason: str
    confidence: float
    source_insight_id: str = ""


def generate(results: list[ClassificationResult]) -> list[Recommendation]:
    recs = []

    for r in results:
        roas = r.evidence.get("roas", 0)

        if r.role == "CONVERSION" and roas >= 6:
            recs.append(Recommendation(
                target_type="CAMPAIGN",
                target_id=r.campaign_id,
                target_name=r.campaign_name,
                action_type="INCREASE_BUDGET",
                current_value={"budget_note": "current"},
                recommended_value={"pct_increase": 20},
                impact_estimate={"expected_roas_maintenance": roas, "conversion_score": r.conversion_score},
                reason=f"ROAS direto {roas:.1f} alto com último toque forte ({r.evidence['last_touch_rate']*100:.0f}%). Budget aumentado captura demanda reprimida.",
                confidence=r.confidence,
            ))

        elif r.role in ("ASSISTED_CONVERSION", "DISCOVERY"):
            recs.append(Recommendation(
                target_type="CAMPAIGN",
                target_id=r.campaign_id,
                target_name=r.campaign_name,
                action_type="DO_NOT_PAUSE",
                current_value={"roas": roas},
                recommended_value={"action": "protect"},
                impact_estimate={"assist_rate": r.evidence["assist_rate"], "assist_score": r.assist_score},
                reason=f"Campanha possui assist_rate {r.evidence['assist_rate']*100:.0f}% e ROAS direto {roas:.1f}. ROAS direto isolado subestima o valor total no funil.",
                confidence=r.confidence,
            ))

            if r.evidence.get("roas", 0) < 3 and r.assist_score > 0.5:
                recs.append(Recommendation(
                    target_type="CAMPAIGN",
                    target_id=r.campaign_id,
                    target_name=r.campaign_name,
                    action_type="DECREASE_BID",
                    current_value={"roas": roas},
                    recommended_value={"pct_decrease": 10},
                    impact_estimate={"rationale": "keep volume, reduce cost slightly"},
                    reason=f"Manter campanha ativa com bid 10% menor: preserva a assistência sem aumentar o custo por jornada.",
                    confidence=round(r.confidence - 0.05, 3),
                ))

        elif r.role == "WASTE":
            pct = 25 if r.waste_score > 0.70 else 15
            recs.append(Recommendation(
                target_type="CAMPAIGN",
                target_id=r.campaign_id,
                target_name=r.campaign_name,
                action_type="DECREASE_BID",
                current_value={"spend": r.evidence["spend"]},
                recommended_value={"pct_decrease": pct},
                impact_estimate={"waste_score": r.waste_score, "potential_savings": r.evidence["spend"] * pct / 100},
                reason=f"R$ {r.evidence['spend']:.0f} gastos sem conversão direta ou assistida. Waste score {r.waste_score:.2f}. Reduzir bid {pct}%.",
                confidence=r.confidence,
            ))
            if r.evidence["spend"] > 300:
                recs.append(Recommendation(
                    target_type="CAMPAIGN",
                    target_id=r.campaign_id,
                    target_name=r.campaign_name,
                    action_type="DECREASE_BUDGET",
                    current_value={"spend": r.evidence["spend"]},
                    recommended_value={"pct_decrease": 30},
                    impact_estimate={"potential_savings": r.evidence["spend"] * 0.3},
                    reason="Gasto alto com desperdício confirmado. Reduzir budget para liberar verba para campanhas conversoras.",
                    confidence=round(r.confidence - 0.05, 3),
                ))

        elif r.role == "REMARKETING":
            recs.append(Recommendation(
                target_type="CAMPAIGN",
                target_id=r.campaign_id,
                target_name=r.campaign_name,
                action_type="CREATE_AUDIENCE",
                current_value={},
                recommended_value={"audience_type": "VIEWED_NOT_PURCHASED", "recency_days": 14},
                impact_estimate={"estimated_pool": "medium", "remarketing_score": r.remarketing_score},
                reason="Criar audiência de visitou-não-comprou (14d) para Sponsored Display e bid boost de Sponsored Products.",
                confidence=r.confidence,
            ))

    return recs

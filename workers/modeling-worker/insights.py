"""
Insight generator — turns ClassificationResult into insight rows.
Spec section 16.2 types.
"""
from dataclasses import dataclass
from typing import Optional
import json

from classifier import ClassificationResult


@dataclass
class Insight:
    insight_type: str
    entity_type: str
    entity_id: str
    entity_name: str
    severity: str
    confidence: float
    score: Optional[float]
    title: str
    summary: str
    evidence_json: str
    recommended_action: str


def generate_campaign_insights(results: list[ClassificationResult], period_start: str, period_end: str) -> list[Insight]:
    insights = []

    for r in results:
        if r.role == "CONVERSION":
            insights.append(Insight(
                insight_type="CAMPAIGN_DIRECT_CONVERTER",
                entity_type="CAMPAIGN",
                entity_id=r.campaign_id,
                entity_name=r.campaign_name,
                severity="INFO",
                confidence=r.confidence,
                score=r.conversion_score,
                title=f"Campanha conversora: {r.campaign_name}",
                summary=f"ROAS direto alto com {r.evidence['direct_conversions']} conversões. Score {r.overall_score}/100. Boa candidata para aumento de budget.",
                evidence_json=json.dumps(r.evidence),
                recommended_action="INCREASE_BUDGET",
            ))

        elif r.role in ("ASSISTED_CONVERSION", "DISCOVERY"):
            insights.append(Insight(
                insight_type="CAMPAIGN_ASSISTS_CONVERSIONS",
                entity_type="CAMPAIGN",
                entity_id=r.campaign_id,
                entity_name=r.campaign_name,
                severity="HIGH",
                confidence=r.confidence,
                score=r.assist_score,
                title=f"Campanha assistida — não pausar: {r.campaign_name}",
                summary=(
                    f"ROAS direto {r.evidence['roas']:.1f} (abaixo da meta), mas assist_rate "
                    f"{r.evidence['assist_rate']*100:.0f}%. Aparece em jornadas que terminam em venda. "
                    "Pausar esta campanha prejudica o funil."
                ),
                evidence_json=json.dumps(r.evidence),
                recommended_action="DO_NOT_PAUSE",
            ))

            if r.role == "ASSISTED_CONVERSION":
                insights.append(Insight(
                    insight_type="DO_NOT_PAUSE_WARNING",
                    entity_type="CAMPAIGN",
                    entity_id=r.campaign_id,
                    entity_name=r.campaign_name,
                    severity="CRITICAL",
                    confidence=min(0.95, r.confidence + 0.05),
                    score=r.assist_score,
                    title=f"ALERTA: não pausar campanha assistida crítica",
                    summary=f"{r.campaign_name} tem assisted_sales > direct_sales e path_presence_rate relevante. Qualquer automação de bid baseada em ROAS direto deve proteger esta campanha.",
                    evidence_json=json.dumps(r.evidence),
                    recommended_action="PROTECT_CAMPAIGN",
                ))

        elif r.role == "WASTE":
            insights.append(Insight(
                insight_type="CAMPAIGN_WASTES_BUDGET",
                entity_type="CAMPAIGN",
                entity_id=r.campaign_id,
                entity_name=r.campaign_name,
                severity="HIGH" if r.evidence["spend"] > 200 else "MEDIUM",
                confidence=r.confidence,
                score=r.waste_score,
                title=f"Campanha desperdiça verba: {r.campaign_name}",
                summary=(
                    f"R$ {r.evidence['spend']:.0f} gastos sem conversão direta nem assistida. "
                    "Waste score alto. Candidato a negativação ou pausa."
                ),
                evidence_json=json.dumps(r.evidence),
                recommended_action="DECREASE_BID",
            ))

        elif r.role == "REMARKETING":
            insights.append(Insight(
                insight_type="AUDIENCE_REMARKETING_OPPORTUNITY",
                entity_type="CAMPAIGN",
                entity_id=r.campaign_id,
                entity_name=r.campaign_name,
                severity="MEDIUM",
                confidence=r.confidence,
                score=r.remarketing_score,
                title=f"Oportunidade de remarketing: {r.campaign_name}",
                summary="Campanha com engajamento relevante. Criar audiência de visitou-não-comprou para Sponsored Display ou bid boost.",
                evidence_json=json.dumps(r.evidence),
                recommended_action="CREATE_AUDIENCE",
            ))

    return insights

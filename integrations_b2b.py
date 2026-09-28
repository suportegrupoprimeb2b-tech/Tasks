"""
========================================================================================
MÓDULO DE INTEGRAÇÃO LOGÍSTICA B2B & AUTOMAÇÕES (PYTHON)
========================================================================================
Este módulo fornece a base arquitetural para:
1. Cruzamento de Ordens de Compra (OCs) com histórico e planejamento de obras.
2. Rastreamento e consulta de status de NF-e (SEFAZ e transportadoras).
3. Web Scraping escalável de catálogos, preços e estoques de distribuidores externos.
========================================================================================
"""

import os
import json
import logging
import asyncio
from datetime import datetime, timezone, timedelta
from typing import Dict, List, Any, Optional
from dataclasses import dataclass, asdict

# Configuração de Logs Estruturados
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] [%(name)s]: %(message)s'
)
logger = logging.getLogger("B2BLogisticsIntegrator")


# --------------------------------------------------------------------------------------
# DATA MODELS (DTOs)
# --------------------------------------------------------------------------------------
@dataclass
class PurchaseOrder:
    order_id: str
    supplier_name: str
    project_id: str
    project_name: str
    sku_list: List[Dict[str, Any]]
    total_value: float
    due_date: str
    status: str
    nfe_key: Optional[str] = None


@dataclass
class ConstructionPhase:
    project_id: str
    phase_name: str
    start_date: str
    deadline_date: str
    budget_allocated: float
    materials_required: List[str]


# --------------------------------------------------------------------------------------
# 1. CRUZAMENTO DE OCS COM HISTÓRICO DE OBRAS (RECONCILER)
# --------------------------------------------------------------------------------------
class PurchaseOrderReconciler:
    """
    Motor de reconciliação de dados de compras contra o histórico físico-financeiro
    de obras da construção civil / projetos corporativos.
    """

    def __init__(self, tolerance_days: int = 2):
        self.tolerance_days = tolerance_days

    def reconcile(
        self,
        orders: List[PurchaseOrder],
        phases: List[ConstructionPhase]
    ) -> Dict[str, Any]:
        """
        Analisa divergências entre prazos de entrega das OCs e etapas de obra.
        """
        logger.info(f"Iniciando reconciliação de {len(orders)} OCs com {len(phases)} fases de obras.")
        
        report = {
            "reconciliation_time": datetime.now(timezone.utc).isoformat(),
            "total_orders_analyzed": len(orders),
            "critical_delays": [],
            "budget_warnings": [],
            "unmatched_orders": []
        }

        phase_map = {p.project_id: p for p in phases}

        for order in orders:
            phase = phase_map.get(order.project_id)
            if not phase:
                report["unmatched_orders"].append({
                    "order_id": order.order_id,
                    "reason": f"Obra {order.project_id} não localizada no cadastro mestre."
                })
                continue

            order_due = datetime.fromisoformat(order.due_date.replace("Z", "+00:00"))
            phase_deadline = datetime.fromisoformat(phase.deadline_date.replace("Z", "+00:00"))

            # Alerta de Atraso Crítico
            if order_due > phase_deadline:
                delay_days = (order_due - phase_deadline).days
                report["critical_delays"].append({
                    "order_id": order.order_id,
                    "project_id": order.project_id,
                    "project_name": order.project_name,
                    "order_due": order.due_date,
                    "phase_deadline": phase.deadline_date,
                    "delay_days": delay_days,
                    "severity": "CRITICAL" if delay_days > 5 else "WARNING"
                })

            # Validação Orçamentária
            if order.total_value > phase.budget_allocated:
                report["budget_warnings"].append({
                    "order_id": order.order_id,
                    "project_id": order.project_id,
                    "order_value": order.total_value,
                    "phase_budget": phase.budget_allocated,
                    "excess": order.total_value - phase.budget_allocated
                })

        logger.info(f"Reconciliação concluída: {len(report['critical_delays'])} atrasos críticos detectados.")
        return report


# --------------------------------------------------------------------------------------
# 2. CONSUMO DE APIS PARA RASTREIO DE NF-E (SEFAZ & TRANSPORTADORAS)
# --------------------------------------------------------------------------------------
class NFeTrackingService:
    """
    Serviço de consulta e normalização de eventos de Notas Fiscais Eletrônicas (NF-e)
    e Conhecimentos de Transporte (CT-e).
    """

    def __init__(self, api_key: str, environment: str = "production"):
        self.api_key = api_key
        self.environment = environment
        self.base_url = "https://api.sefaz-tracker.com.br/v2"

    async def get_nfe_status(self, nfe_key: str) -> Dict[str, Any]:
        """
        Consulta assíncrona do status de uma NF-e através da chave de 44 dígitos.
        """
        if len(nfe_key) != 44 or not nfe_key.isdigit():
            raise ValueError(f"Chave NF-e inválida: {nfe_key}. Deve possuir 44 dígitos.")

        logger.info(f"Consultando SEFAZ/Carrier para a chave NF-e: {nfe_key}")

        # Simulação de chamada HTTP assíncrona (Ex: aiohttp / httpx)
        await asyncio.sleep(0.3)

        return {
            "nfe_key": nfe_key,
            "status_code": 100,
            "status_description": "Autorizado o uso da NF-e",
            "logistics_status": "EM_TRANSITO",
            "carrier_name": "Braspress Transportes Urgentes",
            "last_event": {
                "event_type": "EMISSAO_CTE",
                "location": "Centro de Distribuição Cajamar - SP",
                "timestamp": datetime.now(timezone.utc).isoformat()
            },
            "estimated_delivery": (datetime.now(timezone.utc) + timedelta(days=2)).isoformat()
        }


# --------------------------------------------------------------------------------------
# 3. ROTINAS DE WEB SCRAPING DE DISTRIBUIDORES EXTERNOS
# --------------------------------------------------------------------------------------
class DistributorScraper:
    """
    Engine de Web Scraping modular com suporte a controle de concorrência,
    rotação de User-Agents e extração resiliente de tabelas B2B.
    """

    def __init__(self, distributor_id: str, concurrency_limit: int = 5):
        self.distributor_id = distributor_id
        self.semaphore = asyncio.Semaphore(concurrency_limit)
        self.headers = {
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                          "(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36",
            "Accept-Language": "pt-BR,pt;q=0.9,en-US;q=0.8"
        }

    async def fetch_sku_pricing(self, sku: str) -> Dict[str, Any]:
        """
        Raspa preço de tabela, disponibilidade de estoque e prazo de faturamento.
        """
        async with self.semaphore:
            logger.info(f"[{self.distributor_id}] Coletando dados para o SKU: {sku}")
            
            # Simulação de extração de dados com BeautifulSoup / Playwright
            await asyncio.sleep(0.5)

            return {
                "distributor_id": self.distributor_id,
                "sku": sku,
                "in_stock": True,
                "stock_quantity": 450,
                "unit_price_brl": 89.90,
                "lead_time_days": 3,
                "scraped_at": datetime.now(timezone.utc).isoformat()
            }

    async def scrape_catalog(self, sku_list: List[str]) -> List[Dict[str, Any]]:
        """Executa scraping em lote com paralelismo assíncrono."""
        tasks = [self.fetch_sku_pricing(sku) for sku in sku_list]
        return await asyncio.gather(*tasks)


# --------------------------------------------------------------------------------------
# EXECUÇÃO DE EXEMPLO / TESTE
# --------------------------------------------------------------------------------------
async def main():
    print("\n--- [TESTE 1] RECONCILIAÇÃO DE ORDENS DE COMPRA X OBRAS ---")
    reconciler = PurchaseOrderReconciler(tolerance_days=1)
    
    mock_orders = [
        PurchaseOrder(
            order_id="OC-2026-101",
            supplier_name="Votorantim Cimentos",
            project_id="OBRA-ALPHA",
            project_name="Edifício Alpha Tower",
            sku_list=[{"item": "Cimento CP-II", "qtd": 100}],
            total_value=35000.0,
            due_date="2026-09-08T10:00:00Z",
            status="pending"
        ),
        PurchaseOrder(
            order_id="OC-2026-102",
            supplier_name="Tigre Tubos e Conexões",
            project_id="OBRA-BETA",
            project_name="Residencial Bosque das Palmeiras",
            sku_list=[{"item": "Tubo PVC 100mm", "qtd": 50}],
            total_value=12000.0,
            due_date="2026-09-15T14:00:00Z",
            status="in_progress"
        )
    ]

    mock_phases = [
        ConstructionPhase(
            project_id="OBRA-ALPHA",
            phase_name="Fundações e Estrutura",
            start_date="2026-08-01T00:00:00Z",
            deadline_date="2026-09-05T00:00:00Z",  # Data limite anterior ao prazo da OC!
            budget_allocated=30000.0,             # Menor que o valor da OC!
            materials_required=["Cimento", "Aço", "Areia"]
        )
    ]

    reconcile_result = reconciler.reconcile(mock_orders, mock_phases)
    print(json.dumps(reconcile_result, indent=2, ensure_ascii=False))

    print("\n--- [TESTE 2] RASTREIO ASSÍNCRONO DE NF-E ---")
    nfe_service = NFeTrackingService(api_key="SEFAZ_KEY_PRODUCTION_SAMPLE")
    nfe_status = await nfe_service.get_nfe_status("35260812345678000195550010000123451234567890")
    print(json.dumps(nfe_status, indent=2, ensure_ascii=False))

    print("\n--- [TESTE 3] WEB SCRAPING DE DISTRIBUIDORES ---")
    scraper = DistributorScraper(distributor_id="DISTRIBUIDOR_NACIONAL_ACO")
    catalog_results = await scraper.scrape_catalog(["SKU-TUB-01", "SKU-CIM-50", "SKU-CAB-04"])
    print(json.dumps(catalog_results, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    asyncio.run(main())

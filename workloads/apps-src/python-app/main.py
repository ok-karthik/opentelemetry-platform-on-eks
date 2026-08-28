import os
import time
import logging
from fastapi import FastAPI

# Standard Python logger
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="Python Product Info Service", version="1.0.0")

@app.get("/product-info")
async def product_info():
    # Because of auto-instrumentation, this log will be dynamically 
    # decorated with active trace_id and span_id by the OTel agent!
    logger.info("[Python App] Entering product_info handler...")
    
    time.sleep(80 / 1000)  # Simulate Database transaction latency
    
    logger.info("[Python App] Product info successfully retrieved!")
    return {
        "status": "success",
        "product_id": "prod_123",
        "name": "OTel Observe Book",
        "payment_status": "captured"
    }

@app.get("/health")
async def health():
    return {"status": "healthy"}

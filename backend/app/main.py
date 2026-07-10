import logging
import os
import sys
from contextlib import asynccontextmanager

import asyncpg
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

# Structured JSON logging for CloudWatch parsing
logging.basicConfig(
    stream=sys.stdout,
    level=logging.INFO,
    format='{"ts":"%(asctime)s","level":"%(levelname)s","msg":"%(message)s","logger":"%(name)s"}',
)
log = logging.getLogger("shopnow.backend")

POSTGRES_DSN = os.environ["POSTGRES_DSN"]

state: dict = {}


@asynccontextmanager
async def lifespan(_: FastAPI):
    state["pg"] = await asyncpg.create_pool(POSTGRES_DSN, min_size=1, max_size=5)
    log.info("startup complete")
    yield
    await state["pg"].close()


app = FastAPI(title="ShopNow API", lifespan=lifespan)


class Product(BaseModel):
    name: str
    price: float


@app.get("/healthz")
async def healthz():
    return {"status": "ok"}


@app.get("/readyz")
async def readyz():
    try:
        async with state["pg"].acquire() as conn:
            await conn.fetchval("SELECT 1")
        return {"status": "ready"}
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))


@app.get("/products")
async def list_products():
    async with state["pg"].acquire() as conn:
        rows = await conn.fetch("SELECT id, name, price FROM products ORDER BY id")
    return {"source": "db", "data": [dict(r) for r in rows]}


@app.post("/products")
async def create_product(p: Product):
    async with state["pg"].acquire() as conn:
        pid = await conn.fetchval(
            "INSERT INTO products(name, price) VALUES($1, $2) RETURNING id",
            p.name, p.price,
        )
    return {"id": pid, **p.model_dump()}

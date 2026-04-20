# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT
"""Entry points: pipeline (CronJob) and api (Deployment)."""
import logging
import sys

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)


def run_pipeline() -> None:
    from app.embedding import build_embedding_service
    from app.index_manager import ensure_vector_index
    from app.pipeline import EmbeddingPipeline
    ensure_vector_index()
    svc = build_embedding_service()
    EmbeddingPipeline(svc).run()


def run_api() -> None:
    from app.api import run_server
    from app.index_manager import ensure_vector_index
    ensure_vector_index()
    run_server(host="0.0.0.0", port=9090)


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "api"
    if mode == "pipeline":
        run_pipeline()
    else:
        run_api()

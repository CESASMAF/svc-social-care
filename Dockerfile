# syntax=docker/dockerfile:1.7
FROM swift:6.3-jammy AS build

WORKDIR /build

LABEL org.opencontainers.image.source="https://github.com/acdgbrasil/svc-social-care"
LABEL org.opencontainers.image.description="ACDG svc-social-care service"
LABEL org.opencontainers.image.licenses="Proprietary"

COPY Package.swift Package.resolved ./
# Cache mount (BuildKit) do .build/ — checkouts + artefatos do SwiftPM persistem
# ENTRE builds. As deps (Vapor/NIO/PostgresNIO) param de recompilar.
# sharing=locked: serializa o acesso (Swift build não é concurrency-safe no .build).
RUN --mount=type=cache,target=/build/.build,sharing=locked \
    swift package resolve

COPY Sources ./Sources
COPY Tests ./Tests
# O .build/ é cache mount (NÃO vai pra imagem) → copiar o binário pra FORA do cache
# no MESMO RUN, senão o estágio runtime não o encontra. Builds locais (rebuild):
# ~12min → ~4-6min (deps cacheadas; o módulo próprio recompila em release/WMO).
# Em CI o ganho depende de cache-to/from type=gha no buildx (reusable workflow).
RUN --mount=type=cache,target=/build/.build,sharing=locked \
    swift build -c release --product social-care-s \
    && cp /build/.build/release/social-care-s /build/social-care-s

FROM swift:6.3-jammy-slim

RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/* \
    && groupadd -r appgroup && useradd -r -g appgroup -d /app -s /sbin/nologin appuser

WORKDIR /app
COPY --from=build --chown=appuser:appgroup /build/social-care-s /app/social-care-s

USER appuser

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

CMD ["/app/social-care-s"]

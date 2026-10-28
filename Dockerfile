# Stage 1: build the sponsor.
FROM swift:6.1-jammy AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY Package.swift Package.resolved ./
RUN swift package resolve

COPY Sources Sources
COPY Tests Tests
RUN swift build -c release --static-swift-stdlib --product lattice-sponsor

# Stage 2: Runtime. It runs beside a node, which a deployment copies it next
# to (COPY --from this image); run alone, it needs --node to reach one.
FROM ubuntu:22.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libatomic1 \
    libcurl4 \
    libsqlite3-0 \
    libxml2 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/.build/release/lattice-sponsor /usr/local/bin/lattice-sponsor

RUN useradd -m -s /bin/bash lattice
USER lattice

EXPOSE 8650

ENTRYPOINT ["/usr/local/bin/lattice-sponsor"]

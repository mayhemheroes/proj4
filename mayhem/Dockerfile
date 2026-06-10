# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form) — builds ON TOP of the org C/C++ base image
# (ghcr.io/mayhemheroes/base). The base provides debian + clang/llvm + libFuzzer/afl++ + the
# identities + the build-contract ENV; this only adds the per-commit PROJ (proj4) build.
#
# NOTE: BuildKit reads mayhem/Dockerfile.dockerignore (NOT the repo-root .dockerignore) for this
# build, so the FULL repo incl. .git is baked in even though upstream's root .dockerignore drops it.
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t proj4-commit:test .

FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); never bake it as ENV — an empty value
# breaks clang. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default.
# Declare it WITHOUT a default so an unset arg lets the base ENV flow through; --build-arg overrides.
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# PROJ builds with CMake and needs the sqlite3 CLI (to generate proj.db) + libsqlite3 (to link).
# The unit suite (mayhem/test.sh) builds against external GTest (libgtest-dev) to avoid a network
# FetchContent. Install as root if the base image doesn't already ship them, then drop back to mayhem.
USER root
RUN if ! command -v cmake >/dev/null 2>&1 || ! command -v sqlite3 >/dev/null 2>&1; then \
      [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true; \
      apt-get update && apt-get install -yq --no-install-recommends \
        cmake make sqlite3 libsqlite3-dev pkg-config libgtest-dev \
      && rm -rf /var/lib/apt/lists/*; \
    fi
USER mayhem

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git history)
# is copied to /mayhem as `mayhem`; build.sh builds in place.
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Build expects $SRC to point at the source tree; the base may not set it for an arbitrary repo.
ENV SRC=/mayhem OUT=/mayhem

RUN bash mayhem/build.sh

# Run PROJ's own unit/gie suite at build time (a failing suite fails the image build).
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem

# ==========================
# Stage 1 : Builder (download OpenStego)
# ==========================
FROM python:3.14-slim AS builder

# Optional apt mirror, e.g. --build-arg DEBIAN_MIRROR=https://mirror.truenetwork.ru
# (replaces http://deb.debian.org for both debian and debian-security).
ARG DEBIAN_MIRROR=""
RUN if [ -n "$DEBIAN_MIRROR" ]; then sed -i "s#http://deb.debian.org#${DEBIAN_MIRROR}#g" /etc/apt/sources.list.d/debian.sources; fi

# Install wget only to download OpenStego
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget git build-essential golang-go \
    && rm -rf /var/lib/apt/lists/*

# Download OpenStego
RUN wget https://github.com/syvaidya/openstego/releases/download/openstego-0.8.6/openstego_0.8.6-1_all.deb \
    -O /tmp/openstego.deb

# Clone and build jsteg from source (pinned commit: reproducible builds)
RUN git clone https://github.com/lukechampine/jsteg.git /tmp/jsteg \
    && git -C /tmp/jsteg checkout cf206c26c711db215c11cb61bb479113ae8be275
RUN cd /tmp/jsteg && \
    go build -o /usr/local/bin/jsteg ./cmd/jsteg && \
    rm -rf /tmp/jsteg

# Builder stage - add after other tool compilations (pinned commit)
RUN git clone https://github.com/h3xx/jphs.git /tmp/jphs \
    && git -C /tmp/jphs checkout 33a11e1bad146f5e9c0d3fe6475812a1cedb9b7e
# Vendored autotools helper scripts (docker/) so configure recognizes aarch64
# without a build-time download: git.savannah.gnu.org is flaky/rate-limited,
# and a failed `wget -O` truncates the script, breaking configure entirely.
COPY docker/config.guess docker/config.sub /tmp/jphs/jpeg-8a/
RUN cd /tmp/jphs/jpeg-8a \
    && chmod +x config.guess config.sub \
    && ./configure && make
RUN cd /tmp/jphs && sed -i 's/open(seekfilename,O_WRONLY|O_TRUNC|O_CREAT)/open(seekfilename,O_WRONLY|O_TRUNC|O_CREAT, 0644)/' jpseek.c
RUN cd /tmp/jphs \
    && sed -i 's/^LIBS = .*/JPEG_OBJS = $(filter-out jpeg-8a\/cjpeg.o jpeg-8a\/djpeg.o jpeg-8a\/jpegtran.o jpeg-8a\/rdjpgcom.o jpeg-8a\/wrjpgcom.o,$(wildcard jpeg-8a\/\*.o))/' Makefile \
    && sed -i 's/^LDFLAGS = .*/LDFLAGS =/' Makefile \
    && sed -i 's/^jphide: \(.*\)$/jphide: \1 $(JPEG_OBJS)/' Makefile \
    && sed -i 's/^jpseek: \(.*\)$/jpseek: \1 $(JPEG_OBJS)/' Makefile
RUN cd /tmp/jphs && make all
RUN cd /tmp/jphs && cp jphide jpseek /usr/local/bin/
RUN rm -rf /tmp/jphs

# ==========================
# Stage 1b : Vendored front-end assets (Bootstrap, Font Awesome, Fira Code, jsPDF)
# ==========================
# Downloaded at build time from scripts/vendor_assets.sh, so the files are not
# committed to git and a version bump is a one-line change in that script. The
# layer is cached until the script changes; the final image carries the files,
# so the running site never contacts a public CDN.
FROM alpine:3.22 AS vendor
RUN apk add --no-cache bash curl
WORKDIR /w
COPY scripts/vendor_assets.sh scripts/vendor_assets.sh
RUN bash scripts/vendor_assets.sh

FROM ghcr.io/astral-sh/uv:0.8.22 AS uvbin

# ==========================
# Stage 2 : Image runtime minimale
# ==========================
FROM python:3.14-slim

# Optional apt mirror, e.g. --build-arg DEBIAN_MIRROR=https://mirror.truenetwork.ru
# (replaces http://deb.debian.org for both debian and debian-security).
ARG DEBIAN_MIRROR=""
RUN if [ -n "$DEBIAN_MIRROR" ]; then sed -i "s#http://deb.debian.org#${DEBIAN_MIRROR}#g" /etc/apt/sources.list.d/debian.sources; fi

WORKDIR /app

# uv is only needed at build time: it is bind-mounted into the RUN steps below
# (--mount=from=uvbin) instead of being copied into the image (~48 MB saved).

# Install runtime + stego tools (retries: slow/proxied networks drop long downloads)
RUN echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80retries && apt-get update && apt-get install -y --no-install-recommends \
    expect \
    default-jre-headless \
    file \
    ruby \
    zip \
    p7zip-full \
    binwalk \
    foremost \
    exiftool \
    steghide \
    binutils \
    outguess \
    pngcheck \
    ffmpeg \
    poppler-utils \
    graphicsmagick \
    graphicsmagick-imagemagick-compat \
    && gem install zsteg --no-document \
    && rm -rf /var/lib/apt/lists/*

# Install OpenStego
COPY --from=builder /tmp/openstego.deb /tmp/openstego.deb
# --force-depends: the .deb depends on `default-jre`, and satisfying that through
# `apt-get install -f` would pull the full (GTK/X11) JRE next to the headless one
# installed above. OpenStego is used from the CLI only, so headless is enough.
RUN dpkg -i --force-depends /tmp/openstego.deb \
    && rm -rf /tmp/openstego.deb \
    && rm -rf /var/lib/apt/lists/*

# Python dependencies first, application code after: a code/template/static
# change then rebuilds only the thin layers below instead of reinstalling every
# dependency (and the server pulls tens of MB per release, not hundreds).
COPY pyproject.toml uv.lock ./
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,from=uvbin,source=/uv,target=/bin/uv \
    uv sync --frozen --no-dev --no-install-project
ENV PATH="/app/.venv/bin:$PATH"

COPY aperisolve/ ./aperisolve/
COPY --from=vendor /w/aperisolve/static/vendor ./aperisolve/static/vendor
# Installs only the project itself (dependencies are already in the cached layer).
RUN --mount=type=bind,from=uvbin,source=/uv,target=/bin/uv \
    uv sync --frozen --no-dev

# Compile gettext catalogs (source .po files are committed; .mo are built)
RUN pybabel compile -d aperisolve/translations

# Copy jphide and jsteg binaries
COPY --from=builder /usr/local/bin/jphide /usr/local/bin/jphide
COPY --from=builder /usr/local/bin/jpseek /usr/local/bin/jpseek
COPY --from=builder /usr/local/bin/jsteg /usr/local/bin/jsteg

# Vendored pdfid.py (Didier Stevens, v0.2.10; docker/) for PDF triage. Vendored
# rather than downloaded at build time: didierstevens.com is frequently
# unreachable, and a failed wget used to silently drop pdfid from the image and
# skip the prod deploy. Shebang is pre-normalized to python3 (slim has no bare
# `python`).
COPY docker/pdfid.py /usr/local/bin/pdfid
RUN chmod +x /usr/local/bin/pdfid

# Command to start. `exec` makes gunicorn PID 1 so it receives SIGTERM and
# drains in-flight requests on `docker stop` instead of being SIGKILLed
# (shell form is kept for the ${WEB_WORKERS} expansion).
# The app is I/O-bound (Redis enqueue, Postgres), so a few gthread workers
# serve it with far less RAM than many sync ones; --preload shares the
# imported app between workers (copy-on-write); --max-requests recycles
# workers to cap slow memory growth.
CMD exec gunicorn -w ${WEB_WORKERS:-2} --threads ${WEB_THREADS:-4} --worker-class gthread \
    --preload --worker-tmp-dir /dev/shm --max-requests 2000 --max-requests-jitter 200 \
    -b 0.0.0.0:5000 --access-logfile - --error-logfile - --log-level info --capture-output \
    aperisolve.utils.wsgi:application

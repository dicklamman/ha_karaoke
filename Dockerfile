# syntax=docker/dockerfile:1
#
# Container image for the karaoke web API and player.
#
# Scope: this image runs the web server, the search, the room and the player.
# It does NOT contain the separation models or PyTorch, so it cannot prepare a
# new song from YouTube on its own. Songs that were prepared elsewhere are
# played from the data volume.
#
# The server keeps its state in one directory (SQLite job store plus the
# per-song files) and reads it from KARAOKE_DATA_DIR, so that directory is
# mounted as a volume. Mounting it makes the library survive a rebuild.

FROM python:3.12-slim-bookworm AS base

# ffmpeg/ffprobe: decode, re-encode and mux the prepared media.
# lame: the MP3 previews are written by the LAME frontend, not by ffmpeg.
# nodejs: yt-dlp needs a JavaScript runtime for the YouTube extractors.
# fontconfig: subtitle rendering picks a font by the glyphs a line needs.
# libsndfile1: soundfile reads and writes the WAV masters.
# espeak-ng: the phoneme templates for the fallback alignment.
# tzdata: without the zoneinfo files, a TZ name is ignored and the clock stays
# on UTC, which would shift the subtitle timings.
RUN apt-get update \
    && apt-get install --no-install-recommends -y \
        ffmpeg \
        lame \
        nodejs \
        fontconfig \
        fonts-noto-cjk \
        fonts-noto-core \
        libsndfile1 \
        espeak-ng \
        libespeak-ng1 \
        tzdata \
        curl \
    && rm -rf /var/lib/apt/lists/*

# The server binds 127.0.0.1 by default, which a container cannot be reached
# on from the host, so the address is widened here and the port is published.
ENV KARAOKE_HOST=0.0.0.0 \
    KARAOKE_PORT=8746 \
    KARAOKE_DATA_DIR=/data \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# The dependency files are copied on their own so that a change to the source
# tree does not reinstall the environment. The API requirements are the light
# set: the heavy separation and alignment requirements are not part of this
# image, and installing them here would pull in PyTorch for nothing.
COPY karaoke/requirements-api.txt /app/karaoke/requirements-api.txt

RUN python -m pip install --upgrade pip \
    && python -m pip install -r /app/karaoke/requirements-api.txt \
    # The lyric lookup reaches YouTube Music over plain requests, and the
    # pinned requirements do not name it. Without it the lyric availability
    # endpoint fails with an ImportError while the rest of the server runs.
    && python -m pip install "requests>=2.32"

# The package itself and the web assets. The data directory is separate and
# stays empty in the image, so a fresh volume starts with an empty library.
COPY karaoke /app/karaoke
COPY docs /app/docs

# The server refuses to start a second worker on the same data directory, and
# it locks a file there, so the directory has to be writable by the runtime
# user.
RUN mkdir -p /data \
    && useradd --system --create-home --home-dir /home/karaoke karaoke \
    && chown -R karaoke:karaoke /data /app

USER karaoke

VOLUME ["/data"]
EXPOSE 8746

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${KARAOKE_PORT}/health" || exit 1

# The server takes a single data directory and a single GPU queue, so it runs
# as one process with one worker.
CMD ["python", "-m", "karaoke.api"]

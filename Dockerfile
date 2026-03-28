FROM swift:6.1

# Install build dependencies
RUN apt-get update && apt-get install -y \
    wget build-essential protobuf-compiler curl git \
    && rm -rf /var/lib/apt/lists/*

# Build SQLite from source with snapshot support (required by GRDB)
RUN cd /tmp \
    && wget -q https://www.sqlite.org/2024/sqlite-autoconf-3450100.tar.gz \
    && tar xzf sqlite-autoconf-3450100.tar.gz \
    && cd sqlite-autoconf-3450100 \
    && CFLAGS="-DSQLITE_ENABLE_SNAPSHOT -DSQLITE_ENABLE_FTS5" ./configure --prefix=/usr --quiet > /dev/null 2>&1 \
    && make -j4 -s > /dev/null 2>&1 \
    && make install -s > /dev/null 2>&1 \
    && ldconfig \
    && rm -rf /tmp/sqlite-autoconf-*

# Install Rust (for libsignal later)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

WORKDIR /app

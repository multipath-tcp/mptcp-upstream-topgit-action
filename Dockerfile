FROM ubuntu:24.04

# dependencies for the script
RUN apt-get update && \
    apt-get install -y curl hashalot tar make git gawk && \
    apt-get clean

# TopGit
ARG TG_URL="https://github.com/mackyle/topgit/releases/download/topgit-0.19.13/topgit-0.19.13.tar.gz"
ARG TG_TARBALL="topgit.tar.gz"
ARG TG_SHA="0d97c1b8fbcfd353cfa18cc0ae3e03da90848d5e9364e454f2f616046e1aa8c8  ${TG_TARBALL}"

RUN cd /tmp && \
    curl -L "${TG_URL}" -o "${TG_TARBALL}" && \
    echo "${TG_SHA}" | sha256sum --check && \
    tar xzf "${TG_TARBALL}" && \
    cd "topgit-"* && \
        make prefix="/usr" install && \
        cd .. && \
    rm -rf "${TG_TARBALL}" "topgit-"*

COPY entrypoint.sh /

ENTRYPOINT ["/entrypoint.sh"]

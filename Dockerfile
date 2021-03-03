FROM ubuntu:20.04

# dependencies for the script
RUN apt-get update && \
    apt-get install -y curl hashalot tar make git && \
    apt-get clean

# TopGit
ARG TG_URL="https://github.com/mackyle/topgit/releases/download/topgit-0.19.12/topgit-0.19.12.tar.gz"
ARG TG_TARBALL="topgit.tar.gz"
ARG TG_SHA="8b6b89c55108cc75d007f63818e43aa91b69424b5b8384c06ba2aa3122f5e440  ${TG_TARBALL}"

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

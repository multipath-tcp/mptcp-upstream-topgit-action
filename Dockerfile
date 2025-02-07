FROM ubuntu:24.04

# dependencies for the script
RUN apt-get update && \
    apt-get install -y curl hashalot tar make git gawk && \
    apt-get clean

# TopGit
ARG TG_URL="https://github.com/mackyle/topgit/releases/download/topgit-0.19.14/topgit-0.19.14.tar.gz"
ARG TG_TARBALL="topgit.tar.gz"
ARG TG_SHA="d2dce8e3f04e195c786f7049ce0b5990124ffd58488b509467d59bb0bcac4f0c  ${TG_TARBALL}"

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

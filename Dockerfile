FROM debian:8
MAINTAINER Gonzalo Peci <pecigonzalo@outlook.com>
ENV DEBIAN_FRONTEND noninteractive


RUN apt-get update && \
  apt-get install -y jq libltdl-dev python-pip wget && \
  pip install -U pip && \
  pip install awscli

WORKDIR /

COPY entry.sh /

CMD ["/entry.sh"]

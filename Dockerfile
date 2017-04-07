# A Dockerfile for running Rope unit tests on a Linux environment.
FROM swift:3.1

RUN apt-get update -q &&\
    apt-get install -yq  pkg-config libpq-dev

WORKDIR /code

COPY Package.swift /code/
RUN swift package fetch

# Assuming that tests change less than code, so put Tests before Sources copy
COPY ./Tests /code/Tests
COPY ./Sources /code/Sources
CMD swift test

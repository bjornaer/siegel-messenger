FROM golang:1.26.9-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /server . && mkdir /certs

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /server /server
# Let's Encrypt cache; a named volume mounted here inherits the nonroot owner.
COPY --from=build --chown=65532:65532 /certs /certs
ENTRYPOINT ["/server"]

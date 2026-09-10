FROM golang:1.22

WORKDIR /src
COPY go.mod .
COPY main.go .
RUN CGO_ENABLED=0 go build -o /bin/server .

EXPOSE 8080
CMD ["/bin/server"]

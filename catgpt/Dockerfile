# Builder stage
FROM golang:1.21 as builder

# Set the working directory inside the container
WORKDIR /app

# Copy go mod and sum files
COPY go.mod go.sum ./

# Download all dependencies
RUN go mod download

# Copy the source code into the container
COPY . .

# Build the Go app
RUN CGO_ENABLED=0 go build -o /tmp/catgpt

# Runtime stage
FROM gcr.io/distroless/static-debian12:latest-amd64

# Copy the pre-built binary file from the previous stage
COPY --from=builder /tmp/catgpt /app/

# Command to run the executable
CMD ["/app/catgpt"]

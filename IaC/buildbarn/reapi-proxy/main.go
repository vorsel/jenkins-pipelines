package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"

	remoteexecution "github.com/bazelbuild/remote-apis/build/bazel/remote/execution/v2"
	semver "github.com/bazelbuild/remote-apis/build/bazel/semver"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/reflection"
)

var (
	listenAddr  = flag.String("listen", ":8990", "listen address for capabilities proxy")
	backendAddr = flag.String("backend", "frontend:8980", "BuildBarn frontend address")
)

type capServer struct {
	remoteexecution.UnimplementedCapabilitiesServer
	client remoteexecution.CapabilitiesClient
}

func (s *capServer) GetCapabilities(ctx context.Context, req *remoteexecution.GetCapabilitiesRequest) (*remoteexecution.ServerCapabilities, error) {
	resp, err := s.client.GetCapabilities(ctx, req)
	if err != nil {
		return nil, err
	}

	original := "unknown"
	if resp.LowApiVersion != nil {
		original = formatVer(resp.LowApiVersion)
	}

	resp.DeprecatedApiVersion = &semver.SemVer{Major: 2, Minor: 0, Patch: 0}
	resp.LowApiVersion = &semver.SemVer{Major: 2, Minor: 0, Patch: 0}

	log.Printf("Patched capabilities for %q: low %s -> 2.0.0, high=%s",
		req.InstanceName, original, formatVer(resp.HighApiVersion))
	return resp, nil
}

func formatVer(v *semver.SemVer) string {
	if v == nil {
		return "nil"
	}
	return fmt.Sprintf("%d.%d.%d", v.Major, v.Minor, v.Patch)
}

func main() {
	flag.Parse()

	conn, err := grpc.NewClient(*backendAddr,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithDefaultCallOptions(grpc.MaxCallRecvMsgSize(64*1024*1024)),
	)
	if err != nil {
		log.Fatalf("connect to backend %s: %v", *backendAddr, err)
	}
	defer conn.Close()

	srv := grpc.NewServer()
	remoteexecution.RegisterCapabilitiesServer(srv, &capServer{
		client: remoteexecution.NewCapabilitiesClient(conn),
	})
	reflection.Register(srv)

	lis, err := net.Listen("tcp", *listenAddr)
	if err != nil {
		log.Fatalf("listen %s: %v", *listenAddr, err)
	}
	log.Printf("REAPI capabilities proxy: %s -> %s (patching low_api_version to 2.0.0)", *listenAddr, *backendAddr)
	if err := srv.Serve(lis); err != nil {
		log.Fatalf("serve: %v", err)
	}
}

package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestParseRuncArgs(t *testing.T) {
	command, bundle, id, err := parseRuncArgs([]string{"--root", "/run/runc", "create", "--bundle", "/bundle", "container-id"})
	if err != nil {
		t.Fatal(err)
	}
	if command != "create" || bundle != "/bundle" || id != "container-id" {
		t.Fatalf("unexpected parse result: %q %q %q", command, bundle, id)
	}
}

func TestUpdateOCISpec(t *testing.T) {
	root := t.TempDir()
	t.Setenv("HYPERLIGHT_RUNTIME_ROOT", "/opt/test-runtime")
	path := filepath.Join(root, "config.json")
	input := `{
		"ociVersion":"1.0.2",
		"process":{"user":{"uid":1234,"gid":4321}},
		"linux":{"namespaces":[{"type":"pid"},{"type":"cgroup"}]},
		"mounts":[
			{"destination":"/proc","type":"proc","source":"proc"},
			{"destination":"/sys/fs/cgroup","type":"cgroup2","source":"cgroup","options":["nosuid","nodev","noexec","relatime","ro"]}
		],
		"hooks":{"createRuntime":[{"path":"/existing","args":["/existing"]}]}
	}`
	if err := os.WriteFile(path, []byte(input), 0o640); err != nil {
		t.Fatal(err)
	}
	if err := updateOCISpec(path); err != nil {
		t.Fatal(err)
	}

	var spec struct {
		Mounts []struct {
			Destination string   `json:"destination"`
			Options     []string `json:"options"`
		} `json:"mounts"`
		Hooks map[string][]ociHook `json:"hooks"`
	}
	value, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(value, &spec); err != nil {
		t.Fatal(err)
	}
	if got := spec.Mounts[1].Options[len(spec.Mounts[1].Options)-1]; got != "rw" {
		t.Fatalf("cgroup mount is not writable: %v", spec.Mounts[1].Options)
	}
	if len(spec.Hooks["createRuntime"]) != 2 {
		t.Fatalf("existing hook was not preserved: %#v", spec.Hooks)
	}
	if got := spec.Hooks["createRuntime"][1].Path; got != "/opt/test-runtime/hyperlight-cgroup-hook" {
		t.Fatalf("unexpected hook path: %s", got)
	}
	if got := spec.Hooks["createRuntime"][1].Env; got[0] != "HYPERLIGHT_DELEGATED_UID=1234" || got[1] != "HYPERLIGHT_DELEGATED_GID=4321" {
		t.Fatalf("unexpected delegated identity: %v", got)
	}
	if err := updateOCISpec(path); err != nil {
		t.Fatal(err)
	}
	value, err = os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(value, &spec); err != nil {
		t.Fatal(err)
	}
	if len(spec.Hooks["createRuntime"]) != 2 {
		t.Fatalf("hook was duplicated: %#v", spec.Hooks)
	}
}

func TestUpdateOCISpecRejectsHostCgroupNamespace(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	input := `{
		"process":{"user":{"uid":1000,"gid":1000}},
		"linux":{"namespaces":[{"type":"pid"}]},
		"mounts":[{"destination":"/sys/fs/cgroup","options":["ro"]}]
	}`
	if err := os.WriteFile(path, []byte(input), 0o640); err != nil {
		t.Fatal(err)
	}
	if err := updateOCISpec(path); err == nil {
		t.Fatal("expected missing cgroup namespace to be rejected")
	}
}

func TestUpdateOCISpecRejectsRoot(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	input := `{
		"process":{"user":{"uid":0,"gid":0}},
		"linux":{"namespaces":[{"type":"cgroup"}]},
		"mounts":[{"destination":"/sys/fs/cgroup","options":["ro"]}]
	}`
	if err := os.WriteFile(path, []byte(input), 0o640); err != nil {
		t.Fatal(err)
	}
	if err := updateOCISpec(path); err == nil {
		t.Fatal("expected root process user to be rejected")
	}
}

func TestUpdateOCISpecAllowsRootCRISandbox(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	input := `{
		"annotations":{"io.kubernetes.cri.container-type":"sandbox"},
		"process":{"user":{"uid":0,"gid":0}},
		"linux":{"namespaces":[{"type":"pid"}]},
		"mounts":[{"destination":"/sys/fs/cgroup","options":["ro"]}]
	}`
	if err := os.WriteFile(path, []byte(input), 0o640); err != nil {
		t.Fatal(err)
	}
	if err := updateOCISpec(path); err != nil {
		t.Fatal(err)
	}
	value, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(value) != input {
		t.Fatal("CRI sandbox OCI spec was modified")
	}
}

func TestProcessCgroup(t *testing.T) {
	root := t.TempDir()
	t.Setenv("HYPERLIGHT_PROC_ROOT", root)
	path := filepath.Join(root, "123")
	if err := os.Mkdir(path, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(path, "cgroup"), []byte("0::/kubepods.slice/pod123\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := processCgroup(123)
	if err != nil {
		t.Fatal(err)
	}
	if got != "/kubepods.slice/pod123" {
		t.Fatalf("unexpected cgroup: %s", got)
	}
}

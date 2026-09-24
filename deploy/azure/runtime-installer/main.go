package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	defaultRuntimeRoot = "/opt/hyperlight-runtime"
	defaultStateRoot   = "/run/hyperlight-runtime"
	defaultCgroupRoot  = "/sys/fs/cgroup"
	defaultProcRoot    = "/proc"
	landlockCreateRule = 444
	landlockVersion    = 1
)

type hookState struct {
	ID  string `json:"id"`
	PID int    `json:"pid"`
}

type ociHook struct {
	Path string   `json:"path"`
	Args []string `json:"args"`
	Env  []string `json:"env"`
}

type ociProcess struct {
	User struct {
		UID uint32 `json:"uid"`
		GID uint32 `json:"gid"`
	} `json:"user"`
}

type ociLinux struct {
	Namespaces []struct {
		Type string `json:"type"`
	} `json:"namespaces"`
}

const criContainerTypeAnnotation = "io.kubernetes.cri.container-type"

func main() {
	if len(os.Args) == 2 && os.Args[1] == "landlock-abi" {
		abi, err := landlockABI()
		if err != nil {
			fmt.Fprintf(os.Stderr, "hyperlight runtime: %v\n", err)
			os.Exit(1)
		}
		fmt.Println(abi)
		return
	}

	var err error
	switch filepath.Base(os.Args[0]) {
	case "hyperlight-cgroup-hook":
		err = runHook(os.Stdin)
	default:
		err = runWrapper(os.Args[1:])
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "hyperlight runtime: %v\n", err)
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			os.Exit(exitErr.ExitCode())
		}
		os.Exit(1)
	}
}

func landlockABI() (int, error) {
	abi, _, errno := syscall.Syscall(landlockCreateRule, 0, 0, landlockVersion)
	if errno != 0 {
		return 0, fmt.Errorf("query Landlock ABI: %w", errno)
	}
	return int(abi), nil
}

func runtimeRoot() string {
	if value := os.Getenv("HYPERLIGHT_RUNTIME_ROOT"); value != "" {
		return value
	}
	return defaultRuntimeRoot
}

func stateRoot() string {
	if value := os.Getenv("HYPERLIGHT_STATE_ROOT"); value != "" {
		return value
	}
	return defaultStateRoot
}

func cgroupRoot() string {
	if value := os.Getenv("HYPERLIGHT_CGROUP_ROOT"); value != "" {
		return value
	}
	return defaultCgroupRoot
}

func procRoot() string {
	if value := os.Getenv("HYPERLIGHT_PROC_ROOT"); value != "" {
		return value
	}
	return defaultProcRoot
}

func runWrapper(args []string) error {
	command, bundle, containerID, err := parseRuncArgs(args)
	if err != nil {
		return err
	}

	if command == "create" {
		if bundle == "" {
			return errors.New("OCI bundle is unavailable")
		}
		hookPath := filepath.Join(runtimeRoot(), "hyperlight-cgroup-hook")
		if info, err := os.Stat(hookPath); err != nil || info.Mode()&0o111 == 0 {
			return fmt.Errorf("cgroup hook is not executable: %s", hookPath)
		}
		if err := updateOCISpec(filepath.Join(bundle, "config.json")); err != nil {
			return err
		}
	}

	if command == "delete" {
		if err := cleanup(containerID, hasArgument(args, "--force")); err != nil {
			fmt.Fprintf(os.Stderr, "hyperlight runtime: cleanup before delete: %v\n", err)
		}
	}

	realRunc, err := readRealRunc()
	if err != nil {
		return err
	}
	cmd := exec.Command(realRunc, args...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		if command == "create" {
			_ = cleanup(containerID, true)
		}
		return err
	}
	if command == "delete" {
		if err := cleanup(containerID, true); err != nil {
			fmt.Fprintf(os.Stderr, "hyperlight runtime: cleanup after delete: %v\n", err)
		}
	}
	return nil
}

func hasArgument(args []string, target string) bool {
	for _, argument := range args {
		if argument == target {
			return true
		}
	}
	return false
}

func parseRuncArgs(args []string) (command, bundle, containerID string, err error) {
	for index := 0; index < len(args); index++ {
		switch args[index] {
		case "create", "delete":
			command = args[index]
		case "--bundle", "-b":
			index++
			if index >= len(args) {
				return "", "", "", errors.New("missing bundle argument")
			}
			bundle = args[index]
		}
	}
	if len(args) > 0 {
		containerID = args[len(args)-1]
	}
	if command != "" && containerID == "" {
		return "", "", "", errors.New("container ID is unavailable")
	}
	return command, bundle, containerID, nil
}

func readRealRunc() (string, error) {
	value, err := os.ReadFile(filepath.Join(runtimeRoot(), "real-runc"))
	if err != nil {
		return "", fmt.Errorf("read real runc path: %w", err)
	}
	path := strings.TrimSpace(string(value))
	if !filepath.IsAbs(path) {
		return "", errors.New("real runc path is not absolute")
	}
	if info, err := os.Stat(path); err != nil || info.Mode()&0o111 == 0 {
		return "", fmt.Errorf("real runc is not executable: %s", path)
	}
	return path, nil
}

func updateOCISpec(path string) error {
	original, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("read OCI spec: %w", err)
	}
	var spec map[string]json.RawMessage
	if err := json.Unmarshal(original, &spec); err != nil {
		return fmt.Errorf("decode OCI spec: %w", err)
	}
	var annotations map[string]string
	if raw := spec["annotations"]; len(raw) > 0 && string(raw) != "null" {
		if err := json.Unmarshal(raw, &annotations); err != nil {
			return fmt.Errorf("decode OCI annotations: %w", err)
		}
	}
	if annotations[criContainerTypeAnnotation] == "sandbox" {
		return nil
	}
	var process ociProcess
	if err := json.Unmarshal(spec["process"], &process); err != nil {
		return fmt.Errorf("decode OCI process: %w", err)
	}
	if process.User.UID == 0 {
		return errors.New("delegated runtime requires a non-root process user")
	}
	var linux ociLinux
	if err := json.Unmarshal(spec["linux"], &linux); err != nil {
		return fmt.Errorf("decode OCI Linux settings: %w", err)
	}
	hasCgroupNamespace := false
	for _, namespace := range linux.Namespaces {
		if namespace.Type == "cgroup" {
			hasCgroupNamespace = true
			break
		}
	}
	if !hasCgroupNamespace {
		return errors.New("delegated runtime requires a private cgroup namespace")
	}

	var mounts []map[string]json.RawMessage
	if err := json.Unmarshal(spec["mounts"], &mounts); err != nil {
		return fmt.Errorf("decode OCI mounts: %w", err)
	}
	foundCgroup := false
	for _, mount := range mounts {
		var destination string
		if err := json.Unmarshal(mount["destination"], &destination); err != nil {
			return fmt.Errorf("decode OCI mount destination: %w", err)
		}
		if destination != "/sys/fs/cgroup" {
			continue
		}
		foundCgroup = true
		var options []string
		if raw := mount["options"]; len(raw) > 0 {
			if err := json.Unmarshal(raw, &options); err != nil {
				return fmt.Errorf("decode cgroup mount options: %w", err)
			}
		}
		filtered := make([]string, 0, len(options)+1)
		for _, option := range options {
			if option != "ro" && option != "rw" {
				filtered = append(filtered, option)
			}
		}
		filtered = append(filtered, "rw")
		mount["options"], err = json.Marshal(filtered)
		if err != nil {
			return fmt.Errorf("encode cgroup mount options: %w", err)
		}
	}
	if !foundCgroup {
		return errors.New("OCI spec has no cgroup mount")
	}
	spec["mounts"], err = json.Marshal(mounts)
	if err != nil {
		return fmt.Errorf("encode OCI mounts: %w", err)
	}

	hooks := map[string][]json.RawMessage{}
	if raw := spec["hooks"]; len(raw) > 0 && string(raw) != "null" {
		if err := json.Unmarshal(raw, &hooks); err != nil {
			return fmt.Errorf("decode OCI hooks: %w", err)
		}
	}
	hookPath := filepath.Join(runtimeRoot(), "hyperlight-cgroup-hook")
	for _, raw := range hooks["createRuntime"] {
		var existing ociHook
		if json.Unmarshal(raw, &existing) == nil && existing.Path == hookPath {
			spec["hooks"], err = json.Marshal(hooks)
			if err != nil {
				return fmt.Errorf("encode OCI hooks: %w", err)
			}
			return writeOCISpec(path, spec)
		}
	}
	hookJSON, err := json.Marshal(ociHook{
		Path: hookPath,
		Args: []string{hookPath},
		Env: []string{
			fmt.Sprintf("HYPERLIGHT_DELEGATED_UID=%d", process.User.UID),
			fmt.Sprintf("HYPERLIGHT_DELEGATED_GID=%d", process.User.GID),
		},
	})
	if err != nil {
		return fmt.Errorf("encode cgroup hook: %w", err)
	}
	hooks["createRuntime"] = append(hooks["createRuntime"], hookJSON)
	spec["hooks"], err = json.Marshal(hooks)
	if err != nil {
		return fmt.Errorf("encode OCI hooks: %w", err)
	}

	return writeOCISpec(path, spec)
}

func writeOCISpec(path string, spec map[string]json.RawMessage) error {
	updated, err := json.Marshal(spec)
	if err != nil {
		return fmt.Errorf("encode OCI spec: %w", err)
	}
	info, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("stat OCI spec: %w", err)
	}
	temporary := path + ".hyperlight"
	if err := os.WriteFile(temporary, append(updated, '\n'), info.Mode().Perm()); err != nil {
		return fmt.Errorf("write OCI spec: %w", err)
	}
	if err := os.Rename(temporary, path); err != nil {
		_ = os.Remove(temporary)
		return fmt.Errorf("replace OCI spec: %w", err)
	}
	return nil
}

func runHook(input io.Reader) error {
	var state hookState
	if err := json.NewDecoder(input).Decode(&state); err != nil {
		return fmt.Errorf("decode hook state: %w", err)
	}
	if state.ID == "" || state.PID <= 0 {
		return errors.New("container init process is unavailable")
	}

	relative, err := processCgroup(state.PID)
	if err != nil {
		return err
	}
	if relative == "" || relative == "/" || !filepath.IsAbs(relative) {
		return errors.New("container runtime did not assign a cgroup")
	}

	root := filepath.Join(cgroupRoot(), filepath.Clean(relative))
	application := filepath.Join(root, "application")
	provider := filepath.Join(root, "hyperlight-provider")
	if err := os.MkdirAll(stateRoot(), 0o700); err != nil {
		return fmt.Errorf("create runtime state directory: %w", err)
	}
	stateFile := filepath.Join(stateRoot(), state.ID+".cgroup")
	if err := os.WriteFile(stateFile, []byte(relative+"\n"), 0o600); err != nil {
		return fmt.Errorf("write runtime state: %w", err)
	}
	if err := os.Mkdir(application, 0o755); err != nil {
		return fmt.Errorf("create application cgroup: %w", err)
	}
	if err := os.Mkdir(provider, 0o755); err != nil {
		return fmt.Errorf("create provider cgroup: %w", err)
	}
	if err := writeFile(filepath.Join(application, "cgroup.procs"), strconv.Itoa(state.PID)); err != nil {
		return fmt.Errorf("move application process: %w", err)
	}
	if err := writeFile(filepath.Join(root, "cgroup.subtree_control"), "+cpu +memory +pids"); err != nil {
		return fmt.Errorf("enable container controllers: %w", err)
	}
	if err := writeFile(filepath.Join(provider, "cgroup.subtree_control"), "+cpu +memory +pids"); err != nil {
		return fmt.Errorf("enable provider controllers: %w", err)
	}
	if _, err := os.Stat(filepath.Join(provider, "cgroup.kill")); err != nil {
		return fmt.Errorf("cgroup.kill is unavailable: %w", err)
	}

	uid, err := delegatedID("HYPERLIGHT_DELEGATED_UID", 1000)
	if err != nil {
		return err
	}
	gid, err := delegatedID("HYPERLIGHT_DELEGATED_GID", 1000)
	if err != nil {
		return err
	}
	for _, path := range []string{
		filepath.Join(root, "cgroup.procs"),
		provider,
		filepath.Join(provider, "cgroup.procs"),
		filepath.Join(provider, "cgroup.subtree_control"),
		filepath.Join(provider, "cgroup.kill"),
	} {
		if err := os.Chown(path, uid, gid); err != nil {
			return fmt.Errorf("delegate %s: %w", path, err)
		}
	}
	return nil
}

func processCgroup(pid int) (string, error) {
	file, err := os.Open(filepath.Join(procRoot(), strconv.Itoa(pid), "cgroup"))
	if err != nil {
		return "", fmt.Errorf("read container cgroup: %w", err)
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		parts := strings.SplitN(scanner.Text(), ":", 3)
		if len(parts) == 3 && parts[0] == "0" {
			return parts[2], nil
		}
	}
	if err := scanner.Err(); err != nil {
		return "", fmt.Errorf("scan container cgroup: %w", err)
	}
	return "", errors.New("unified cgroup entry is unavailable")
}

func delegatedID(name string, fallback int) (int, error) {
	value := os.Getenv(name)
	if value == "" {
		return fallback, nil
	}
	id, err := strconv.Atoi(value)
	if err != nil || id < 0 {
		return 0, fmt.Errorf("%s is invalid", name)
	}
	return id, nil
}

func writeFile(path, value string) error {
	return os.WriteFile(path, []byte(value+"\n"), 0)
}

func cleanup(containerID string, killApplication bool) error {
	if containerID == "" || strings.ContainsRune(containerID, filepath.Separator) {
		return errors.New("invalid container ID")
	}
	stateFile := filepath.Join(stateRoot(), containerID+".cgroup")
	value, err := os.ReadFile(stateFile)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("read runtime state: %w", err)
	}
	relative := strings.TrimSpace(string(value))
	if relative == "" || relative == "/" || !filepath.IsAbs(relative) {
		return errors.New("invalid saved cgroup path")
	}
	root := filepath.Join(cgroupRoot(), filepath.Clean(relative))
	provider := filepath.Join(root, "hyperlight-provider")
	application := filepath.Join(root, "application")

	if _, err := os.Stat(filepath.Join(provider, "cgroup.kill")); err == nil {
		_ = writeFile(filepath.Join(provider, "cgroup.kill"), "1")
	}
	if killApplication {
		if _, err := os.Stat(filepath.Join(application, "cgroup.kill")); err == nil {
			_ = writeFile(filepath.Join(application, "cgroup.kill"), "1")
		}
	}
	if err := waitUnpopulated(provider); err != nil {
		return err
	}
	if err := removeCgroupTree(provider); err != nil {
		return fmt.Errorf("provider cgroup cleanup failed: %w", err)
	}
	if err := waitUnpopulated(application); err != nil {
		return err
	}
	if err := os.Remove(application); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("application cgroup cleanup failed: %w", err)
	}
	if err := os.Remove(stateFile); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("remove runtime state: %w", err)
	}
	return nil
}

func waitUnpopulated(group string) error {
	events := filepath.Join(group, "cgroup.events")
	for attempts := 0; attempts < 100; attempts++ {
		populated, err := cgroupPopulated(events)
		if errors.Is(err, os.ErrNotExist) || !populated {
			return nil
		}
		if err != nil {
			return fmt.Errorf("read cgroup state: %w", err)
		}
		time.Sleep(10 * time.Millisecond)
	}
	return fmt.Errorf("cgroup remained populated: %s", group)
}

func cgroupPopulated(path string) (bool, error) {
	value, err := os.ReadFile(path)
	if err != nil {
		return false, err
	}
	for _, line := range bytes.Split(value, []byte{'\n'}) {
		if string(line) == "populated 1" {
			return true, nil
		}
	}
	return false, nil
}

func removeCgroupTree(root string) error {
	entries, err := os.ReadDir(root)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if entry.IsDir() {
			if err := removeCgroupTree(filepath.Join(root, entry.Name())); err != nil {
				return err
			}
		}
	}
	if err := syscall.Rmdir(root); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

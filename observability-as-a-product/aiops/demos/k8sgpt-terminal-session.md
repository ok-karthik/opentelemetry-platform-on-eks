# k8sgpt Terminal Session Transcript

This transcript captures the live execution of **Phase 1 (CNCF k8sgpt cluster diagnosis)** against the test workloads in namespace `aiops-demo`.

---

## 1. Environment & Fault Injection

Deploy the two test workloads from [`faulty-workloads.yaml`](faulty-workloads.yaml):

```console
$ k8sgpt version
k8sgpt: 0.4.39 (Homebrew), built at: 2026-09-14T13:54:52Z

$ kubectl apply -f faulty-workloads.yaml
deployment.apps/oomkill-product-service created
deployment.apps/probe-failure-service created

$ kubectl get pods -n aiops-demo
NAME                                       READY   STATUS      RESTARTS   AGE
oomkill-product-service-654f6d8fdb-pxdch   0/1     OOMKilled   0          8s
probe-failure-service-6798f958df-kp4lw    0/1     Running     0          8s
```

---

## 2. Rule-Based AST Analysis (Zero-Code, Offline)

Running `k8sgpt analyze` without external AI APIs demonstrates how native Kubernetes AST filters isolate the root cause immediately:

```console
$ k8sgpt analyze -n aiops-demo --filter=Pod,Deployment --with-doc
AI Provider: AI not used; --explain not set

0: Pod aiops-demo/oomkill-product-service-654f6d8fdb-pxdch(Deployment/oomkill-product-service)
- Error: the last termination reason is OOMKilled container=memory-eater pod=oomkill-product-service-654f6d8fdb-pxdch

1: Pod aiops-demo/probe-failure-service-6798f958df-kp4lw(Deployment/probe-failure-service)
- Error: Readiness probe failed: Get "http://192.168.194.43:8088/healthz-does-not-exist": dial tcp 192.168.194.43:8088: connect: connection refused

2: Deployment aiops-demo/oomkill-product-service()
- Error: Deployment aiops-demo/oomkill-product-service has 1 replicas but 0 are available with status running

3: Deployment aiops-demo/probe-failure-service()
- Error: Deployment aiops-demo/probe-failure-service has 1 replicas but 0 are available with status running
```

---

## 3. LLM-Assisted Remediation (`--explain`)

With OpenAI / Azure / local LLM integration enabled, `k8sgpt` augments the diagnostic findings with prescriptive remediation steps:

```console
$ k8sgpt analyze -n aiops-demo --filter=Pod,Deployment --explain
AI Provider: openai (model: gpt-4o-mini)

0: Pod aiops-demo/oomkill-product-service-654f6d8fdb-pxdch(Deployment/oomkill-product-service)
> Explanation:
> The container 'memory-eater' was terminated due to an Out Of Memory (OOM) error (exitCode 137). 
> The application attempted to allocate more memory than the configured limit of 15Mi.
> 
> How to resolve:
> 1. Increase the container memory limits in spec.containers[0].resources.limits.memory.
> 2. Inspect application memory usage profiling or leak issues.

1: Pod aiops-demo/probe-failure-service-6798f958df-kp4lw(Deployment/probe-failure-service)
> Explanation:
> The readiness probe failed because the container is not listening on port 8088 at path '/healthz-does-not-exist',
> resulting in 'connection refused'. Because the readiness probe fails, Kubernetes will not route traffic to this pod.
>
> How to resolve:
> 1. Verify the application server port (e.g. port 80 or 8080).
> 2. Update the readinessProbe.httpGet configuration with the valid endpoint path and port.
```

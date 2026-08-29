import os
from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import EKS
from diagrams.aws.storage import S3
from diagrams.aws.management import Cloudwatch
from diagrams.k8s.compute import DaemonSet, Deployment, Pod
from diagrams.onprem.monitoring import Grafana
from diagrams.onprem.logging import Loki
from diagrams.onprem.tracing import Tempo
from diagrams.programming.language import Go, Python

script_dir = os.path.dirname(os.path.abspath(__file__))
diagram_filename = os.path.join(script_dir, "single_cluster_architecture")

graph_attr = {
    "pad": "0.5",
    "nodesep": "0.8",
    "ranksep": "1.2",
    "splines": "spline",
    "fontsize": "20",
    "dpi": "300"
}

node_attr = {
    "fontsize": "13"
}

cluster_attr = {
    "fontsize": "15",
    "margin": "20"
}

with Diagram(
    "Amazon EKS Observability Platform (Single-Cluster Mode)",
    show=False,
    filename=diagram_filename,
    outformat="png",
    direction="LR",
    graph_attr=graph_attr,
    node_attr=node_attr
):
    with Cluster("Amazon EKS Cluster (VPC 10.0.0.0/16)", graph_attr=cluster_attr):
        
        # Namespace: default
        with Cluster("Namespace: default (Application Workloads)", graph_attr=cluster_attr):
            go_app = Pod("Go Product Service\n(Programmatic SDK)")
            py_app = Pod("Python Info Service\n(Auto-Instrumented)")
            obi_ebpf = DaemonSet("OBI eBPF Agent\n(Kernel TCP/HTTP RED)")
            otel_daemon = DaemonSet("OTel DaemonSet (:4317)\nk8sattributes + filelog")

            go_app >> Edge(style="dashed", label="W3C Context") >> py_app
            go_app >> Edge(color="darkorange", label="status.hostIP") >> otel_daemon
            py_app >> Edge(color="darkorange", label="status.hostIP") >> otel_daemon
            obi_ebpf >> Edge(color="purple", label="Loopback") >> otel_daemon

        # Namespace: monitoring
        with Cluster("Namespace: monitoring (Observability Platform)", graph_attr=cluster_attr):
            
            with Cluster("Central OTel Gateway Fleet", graph_attr=cluster_attr):
                router = Deployment("Tier 1: Router\n(Consistent Hashing)")
                processor = Deployment("Tier 2: Processor\n(Tail-Sampling + OTTL)")
                router >> Edge(label="gRPC :4319\n(Trace Affinity)") >> processor

            with Cluster("Storage Backends (S3 & Serverless)", graph_attr=cluster_attr):
                amp = Cloudwatch("Amazon Managed\nPrometheus (AMP)")
                loki = Loki("Grafana Loki\n(S3 Logs)")
                tempo = Tempo("Grafana Tempo\n(S3 Traces)")

            grafana = Grafana("Grafana UI\n(Unified Single-Pane)")

            grafana >> Edge(color="darkorange", label="SigV4 PromQL") >> amp
            grafana >> Edge(color="firebrick", label="LogQL") >> loki
            grafana >> Edge(color="royalblue", label="TraceQL") >> tempo

        otel_daemon >> Edge(color="darkblue", label="OTLP / CoreDNS") >> router
        processor >> Edge(color="darkorange", label="SigV4 Remote Write") >> amp
        processor >> Edge(color="firebrick", label="Native OTLP") >> loki
        processor >> Edge(color="royalblue", label="OTLP") >> tempo

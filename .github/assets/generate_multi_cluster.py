import os
from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import EKS
from diagrams.aws.network import ALB, VPCPeering, NLB
from diagrams.aws.general import Users
from diagrams.aws.storage import S3
from diagrams.k8s.compute import Pod, DaemonSet, Deployment
from diagrams.onprem.monitoring import Grafana, Prometheus
from diagrams.onprem.logging import Loki
from diagrams.onprem.tracing import Tempo

script_dir = os.path.dirname(os.path.abspath(__file__))
diagram_filename = os.path.join(script_dir, "multi_cluster_architecture")

graph_attr = {
    "pad": "0.5",
    "nodesep": "0.8",
    "ranksep": "1.5",
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
    "Amazon EKS Observability Platform (Multi-Cluster Peered Mode)",
    show=False,
    filename=diagram_filename,
    outformat="png",
    direction="LR",
    graph_attr=graph_attr,
    node_attr=node_attr
):
    users = Users("Users / Traffic")

    with Cluster("VPC 1: Workload VPC (10.0.0.0/16)", graph_attr=cluster_attr):
        alb = ALB("Ingress ALB")
        
        with Cluster("EKS Workload Cluster (apps-workload-cluster-1)", graph_attr=cluster_attr):
            go_app = Pod("Go Product Service\n(Programmatic SDK)")
            py_app = Pod("Python Info Service\n(Auto-Instrumented)")
            obi_ebpf = DaemonSet("OBI eBPF Agent\n(Rate, Errors, Duration)")
            otel_agent = DaemonSet("Tier 1: OTel Agent (:4317/:4318)\nk8sattributes + filelog")

            alb >> go_app
            go_app >> Edge(style="dashed", label="W3C Context") >> py_app
            go_app >> Edge(color="darkorange", label="status.hostIP") >> otel_agent
            py_app >> Edge(color="darkorange", label="status.hostIP") >> otel_agent
            obi_ebpf >> Edge(color="purple", label="Loopback (:4318)") >> otel_agent

    vpc_peering = VPCPeering("VPC Peering\n(AWS Private Network)")

    with Cluster("VPC 2: Observability VPC (10.1.0.0/16)", graph_attr=cluster_attr):
        nlb = NLB("Internal NLB\n(Ingress Router)")
        
        with Cluster("EKS Observability Cluster (observability-cluster)", graph_attr=cluster_attr):
            with Cluster("Central OTel Gateway Fleet", graph_attr=cluster_attr):
                router = Deployment("Tier 2: Stateless Router\n(Consistent Hashing)")
                processor = Deployment("Tier 3: Stateful Processor\n(Tail-Sampling + OTTL)")
                router >> Edge(label="gRPC :4319\n(Trace Affinity)") >> processor

            with Cluster("Storage Backends (S3 & Prometheus)", graph_attr=cluster_attr):
                mimir_prom = Prometheus("Mimir / Prometheus\n(Metrics in S3/AMP)")
                loki = Loki("Grafana Loki\n(S3 Logs)")
                tempo = Tempo("Grafana Tempo\n(S3 Traces)")

            grafana = Grafana("Grafana UI\n(Unified Single-Pane)")

            grafana >> Edge(color="darkorange", label="PromQL") >> mimir_prom
            grafana >> Edge(color="firebrick", label="LogQL") >> loki
            grafana >> Edge(color="royalblue", label="TraceQL") >> tempo

        processor >> Edge(color="darkorange", label="Remote Write") >> mimir_prom
        processor >> Edge(color="firebrick", label="Native OTLP") >> loki
        processor >> Edge(color="royalblue", label="OTLP (zstd)") >> tempo

    users >> alb
    otel_agent >> Edge(color="darkblue", label="OTLP gRPC (zstd)") >> vpc_peering >> nlb >> router


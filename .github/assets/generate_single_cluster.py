from diagrams.k8s.compute import StatefulSet
import os
from diagrams import Cluster, Diagram, Edge
from diagrams.k8s.compute import DaemonSet, Deployment, Pod
from diagrams.onprem.monitoring import Grafana, Prometheus
from diagrams.onprem.logging import Loki
from diagrams.onprem.tracing import Tempo

script_dir = os.path.dirname(os.path.abspath(__file__))
diagram_filename = os.path.join(script_dir, "single_cluster_architecture")

graph_attr = {
    "pad": "0.5",
    "nodesep": "0.8",
    "ranksep": "2.2", 
    "splines": "spline",
    "fontsize": "20",
    "dpi": "300"
}

node_attr = {
    "fontsize": "13"
}

stack_bottom = {"bgcolor": "#CBD5E1", "margin": "12", "penwidth": "1"} 
stack_middle = {"bgcolor": "#F1F5F9", "margin": "12", "penwidth": "1"} 
stack_top    = {"bgcolor": "#FFFFFF", "margin": "25", "penwidth": "1"} 

with Diagram(
    "Amazon EKS Topology (Nodes & Scalable Workloads)",
    show=False,
    filename=diagram_filename,
    outformat="png",
    direction="LR",
    graph_attr=graph_attr,
    node_attr=node_attr
):
    with Cluster("Amazon EKS Cluster (VPC 10.1.0.0/16)", graph_attr={"fontsize": "15", "margin": "25"}):
        
        # 1. Application Node Pool
        with Cluster("Worker Nodes (App Pool)", graph_attr=stack_bottom):
            with Cluster("", graph_attr=stack_middle):
                with Cluster("", graph_attr=stack_top):
                    
                    # Grouping workloads in a dashed container on the left
                    with Cluster("App Workloads", graph_attr={"bgcolor": "transparent", "style": "dashed", "penwidth": "2"}):
                        go_app = Pod("Go Product Service\n(Programmatic SDK)")
                        py_app = Pod("Python Info Service\n(Auto-Instrumented)")
                    
                    # Declared independently so they sit to the right of the dashed container
                    with Cluster("Host-Level Agents", graph_attr={"bgcolor": "transparent", "penwidth": "0", "margin": "0"}):
                        obi_ebpf = DaemonSet("OBI eBPF Agent\n(Rate, Errors, Duration)")
                        otel_daemon = DaemonSet("Tier 1: OTel Agent DaemonSet\n(k8sattributes + filelog :4317/:4318)")

        # 2. Observability Node Pool
        with Cluster("Worker Nodes (Observability Pool)", graph_attr=stack_bottom):
            with Cluster("", graph_attr=stack_middle):
                with Cluster("", graph_attr=stack_top):
                    router = Deployment("Tier 2: Stateless Router\n(Deployment + HPA)")
                    processor = StatefulSet("Tier 3: Stateful Processor\n(StatefulSet + Tail Sampling)")

        # Storage Backends
        with Cluster("Storage Backends (S3 & Prometheus)", graph_attr={"fontsize": "15", "margin": "25"}):
            tempo = Tempo("Grafana Tempo\n(Traces in S3)")
            loki = Loki("Grafana Loki\n(Logs in S3)")
            mimir_prom = Prometheus("Mimir / Prometheus\n(Metrics in S3/AMP)")

        grafana = Grafana("Grafana UI\n(Unified Single-Pane)")

    # ==========================================
    # STRUCTURAL ROUTING HACKS (THE MAGIC)
    # ==========================================
    
    # 1. Pull the Go App to the TOP-LEFT
    go_app >> Edge(style="invis") >> router

    # 2. Push the DaemonSets to the BOTTOM-RIGHT by linking to the bottom app INVISIBLY.
    # This physically drops the agents into the corner without cluttering the diagram with lines.
    py_app >> Edge(style="invis") >> obi_ebpf
    
    # 3. Keep the W3C Context visually without breaking the layout.
    go_app >> Edge(style="dashed", label="W3C Context", constraint="false") >> py_app

    # ==========================================
    # STANDARD DATA FLOW
    # ==========================================

    # OBI eBPF talks to OTel Collector over the node loopback (hostNetwork: true)
    obi_ebpf >> Edge(color="purple", label="Loopback (:4318)") >> otel_daemon

    # Egress from DaemonSet to Gateway Router
    otel_daemon >> Edge(color="darkblue", label="OTLP gRPC (zstd)", penwidth="2") >> router

    # Gateway internal routing
    router >> Edge(label="gRPC :4319\n(Trace-ID Hash)") >> processor

    # Egress to Storage Backends
    processor >> Edge(color="royalblue", label="OTLP (zstd)") >> tempo
    processor >> Edge(color="firebrick", label="Native OTLP") >> loki
    processor >> Edge(color="darkorange", label="Remote Write") >> mimir_prom

    # The Reverse Edge Trick (UI Queries)
    mimir_prom >> Edge(dir="back", color="darkorange", label="PromQL") >> grafana
    loki >> Edge(dir="back", color="firebrick", label="LogQL") >> grafana
    tempo >> Edge(dir="back", color="royalblue", label="TraceQL") >> grafana
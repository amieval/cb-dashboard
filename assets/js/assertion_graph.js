// D3 force-directed graph hook for the assertion DAG
// Receives graph_data events from LiveView, renders with D3
// Pushes select_node events back to LiveView on click
import * as d3 from "d3";

const KIND_COLORS = {
  primitive: "#58a6ff",
  compound: "#3fb950",
  implication: "#d29922",
  patch: "#bc8cff",
  contract: "#f85149",
};

const STATUS_OPACITY = {
  active: 1.0,
  superseded: 0.4,
  retracted: 0.25,
};

export const AssertionGraph = {
  mounted() {
    this.nodes = [];
    this.edges = [];
    this.simulation = null;
    this.selectedId = null;
    this.highlightDeps = new Set();
    this.highlightDependents = new Set();

    this.initSVG();

    this.handleEvent("graph_data", (data) => {
      this.updateGraph(data);
    });

    this.handleEvent("highlight", (data) => {
      this.selectedId = data.selected;
      this.highlightDeps = new Set(data.deps || []);
      this.highlightDependents = new Set(data.dependents || []);
      this.applyHighlight();
    });

    // Resize handler
    this.resizeObserver = new ResizeObserver(() => {
      const { width, height } = this.el.getBoundingClientRect();
      this.svg.attr("width", width).attr("height", height);
      if (this.simulation) {
        this.simulation.force("center", d3.forceCenter(width / 2, height / 2));
        this.simulation.alpha(0.1).restart();
      }
    });
    this.resizeObserver.observe(this.el);
  },

  destroyed() {
    if (this.resizeObserver) this.resizeObserver.disconnect();
    if (this.simulation) this.simulation.stop();
  },

  initSVG() {
    const { width, height } = this.el.getBoundingClientRect();

    this.svg = d3
      .select(this.el)
      .append("svg")
      .attr("width", width)
      .attr("height", height)
      .style("background", "#0d1117");

    // Arrow marker for edges
    const defs = this.svg.append("defs");
    defs
      .append("marker")
      .attr("id", "arrowhead")
      .attr("viewBox", "0 -5 10 10")
      .attr("refX", 20)
      .attr("refY", 0)
      .attr("markerWidth", 6)
      .attr("markerHeight", 6)
      .attr("orient", "auto")
      .append("path")
      .attr("d", "M0,-5L10,0L0,5")
      .attr("fill", "#30363d");

    defs
      .append("marker")
      .attr("id", "arrowhead-highlight")
      .attr("viewBox", "0 -5 10 10")
      .attr("refX", 20)
      .attr("refY", 0)
      .attr("markerWidth", 6)
      .attr("markerHeight", 6)
      .attr("orient", "auto")
      .append("path")
      .attr("d", "M0,-5L10,0L0,5")
      .attr("fill", "#58a6ff");

    // Zoom container
    this.container = this.svg.append("g");
    this.edgeGroup = this.container.append("g").attr("class", "edges");
    this.nodeGroup = this.container.append("g").attr("class", "nodes");
    this.labelGroup = this.container.append("g").attr("class", "labels");

    // Zoom behavior
    const zoom = d3
      .zoom()
      .scaleExtent([0.1, 4])
      .on("zoom", (event) => {
        this.container.attr("transform", event.transform);
      });

    this.svg.call(zoom);

    // Tooltip
    this.tooltip = d3
      .select(this.el)
      .append("div")
      .style("position", "absolute")
      .style("pointer-events", "none")
      .style("background", "#161b22")
      .style("border", "1px solid #30363d")
      .style("border-radius", "6px")
      .style("padding", "8px 12px")
      .style("font-size", "12px")
      .style("color", "#e6edf3")
      .style("max-width", "300px")
      .style("opacity", 0)
      .style("z-index", 100);
  },

  updateGraph(data) {
    const { width, height } = this.el.getBoundingClientRect();

    // Build node map for edge resolution
    const nodeMap = new Map(data.nodes.map((n) => [n.id, n]));

    // Compute in-degree for sizing
    const inDegree = new Map();
    data.edges.forEach((e) => {
      inDegree.set(e.target, (inDegree.get(e.target) || 0) + 1);
    });

    // Preserve positions from existing nodes
    const oldPositions = new Map();
    this.nodes.forEach((n) => {
      if (n.x !== undefined) oldPositions.set(n.id, { x: n.x, y: n.y });
    });

    this.nodes = data.nodes.map((n) => {
      const old = oldPositions.get(n.id);
      return {
        ...n,
        x: old ? old.x : width / 2 + (Math.random() - 0.5) * 400,
        y: old ? old.y : height / 2 + (Math.random() - 0.5) * 400,
        radius: Math.max(5, Math.min(14, 5 + (inDegree.get(n.id) || 0) * 2)),
      };
    });

    const nodeById = new Map(this.nodes.map((n) => [n.id, n]));

    this.edges = data.edges
      .filter((e) => nodeById.has(e.source) && nodeById.has(e.target))
      .map((e) => ({
        source: nodeById.get(e.source),
        target: nodeById.get(e.target),
      }));

    this.renderGraph(width, height);
  },

  renderGraph(width, height) {
    const self = this;

    // Stop old simulation
    if (this.simulation) this.simulation.stop();

    // Force simulation
    this.simulation = d3
      .forceSimulation(this.nodes)
      .force(
        "link",
        d3
          .forceLink(this.edges)
          .id((d) => d.id)
          .distance(80)
          .strength(0.5)
      )
      .force("charge", d3.forceManyBody().strength(-200).distanceMax(500))
      .force("center", d3.forceCenter(width / 2, height / 2))
      .force("collision", d3.forceCollide().radius((d) => d.radius + 4))
      .force("x", d3.forceX(width / 2).strength(0.03))
      .force("y", d3.forceY(height / 2).strength(0.03));

    // Edges
    const edgeSel = this.edgeGroup
      .selectAll("line")
      .data(this.edges, (d) => `${d.source.id}-${d.target.id}`);

    edgeSel.exit().remove();

    const edgeEnter = edgeSel
      .enter()
      .append("line")
      .attr("stroke", "#30363d")
      .attr("stroke-width", 1)
      .attr("marker-end", "url(#arrowhead)");

    this.edgeElements = edgeEnter.merge(edgeSel);

    // Nodes
    const nodeSel = this.nodeGroup
      .selectAll("circle")
      .data(this.nodes, (d) => d.id);

    nodeSel.exit().remove();

    const nodeEnter = nodeSel
      .enter()
      .append("circle")
      .attr("r", (d) => d.radius)
      .attr("fill", (d) => KIND_COLORS[d.kind] || "#6e7681")
      .attr("stroke", "#0d1117")
      .attr("stroke-width", 1.5)
      .attr("opacity", (d) => STATUS_OPACITY[d.status] || 0.5)
      .style("cursor", "pointer")
      .call(this.drag())
      .on("click", (event, d) => {
        event.stopPropagation();
        self.pushEvent("select_node", { id: d.id });
      })
      .on("mouseover", (event, d) => {
        self.tooltip
          .html(
            `<strong>${d.id}</strong> <span style="color:${KIND_COLORS[d.kind]}">${d.kind}</span><br/><span style="color:#8b949e">${d.claim ? d.claim.substring(0, 120) : ""}${d.claim && d.claim.length > 120 ? "..." : ""}</span>`
          )
          .style("opacity", 1);
      })
      .on("mousemove", (event) => {
        const rect = self.el.getBoundingClientRect();
        self.tooltip
          .style("left", event.clientX - rect.left + 12 + "px")
          .style("top", event.clientY - rect.top - 10 + "px");
      })
      .on("mouseout", () => {
        self.tooltip.style("opacity", 0);
      });

    this.nodeElements = nodeEnter.merge(nodeSel);
    this.nodeElements
      .attr("r", (d) => d.radius)
      .attr("fill", (d) => KIND_COLORS[d.kind] || "#6e7681")
      .attr("opacity", (d) => STATUS_OPACITY[d.status] || 0.5);

    // Labels (ID text)
    const labelSel = this.labelGroup
      .selectAll("text")
      .data(this.nodes, (d) => d.id);

    labelSel.exit().remove();

    const labelEnter = labelSel
      .enter()
      .append("text")
      .text((d) => d.id)
      .attr("font-size", 9)
      .attr("fill", "#6e7681")
      .attr("text-anchor", "middle")
      .attr("dy", (d) => -d.radius - 4)
      .style("pointer-events", "none")
      .style("user-select", "none");

    this.labelElements = labelEnter.merge(labelSel);

    // Background click to deselect
    this.svg.on("click", () => {
      self.pushEvent("deselect", {});
    });

    // Tick
    this.simulation.on("tick", () => {
      this.edgeElements
        .attr("x1", (d) => d.source.x)
        .attr("y1", (d) => d.source.y)
        .attr("x2", (d) => d.target.x)
        .attr("y2", (d) => d.target.y);

      this.nodeElements.attr("cx", (d) => d.x).attr("cy", (d) => d.y);

      this.labelElements.attr("x", (d) => d.x).attr("y", (d) => d.y - d.radius - 4);
    });

    // Apply any existing highlight
    this.applyHighlight();
  },

  applyHighlight() {
    if (!this.nodeElements) return;

    const sel = this.selectedId;
    const deps = this.highlightDeps;
    const dependents = this.highlightDependents;
    const hasHighlight = sel != null;

    this.nodeElements
      .attr("opacity", (d) => {
        if (!hasHighlight) return STATUS_OPACITY[d.status] || 0.5;
        if (d.id === sel) return 1;
        if (deps.has(d.id) || dependents.has(d.id)) return 0.9;
        return 0.15;
      })
      .attr("stroke", (d) => {
        if (d.id === sel) return "#e6edf3";
        if (deps.has(d.id)) return "#58a6ff";
        if (dependents.has(d.id)) return "#d29922";
        return "#0d1117";
      })
      .attr("stroke-width", (d) => {
        if (d.id === sel) return 3;
        if (deps.has(d.id) || dependents.has(d.id)) return 2;
        return 1.5;
      });

    this.edgeElements
      .attr("stroke", (d) => {
        if (!hasHighlight) return "#30363d";
        const srcId = d.source.id || d.source;
        const tgtId = d.target.id || d.target;
        // dep edges: from dep -> selected
        if (deps.has(srcId) && tgtId === sel) return "#58a6ff";
        // dependent edges: from selected -> dependent
        if (srcId === sel && dependents.has(tgtId)) return "#d29922";
        if (deps.has(srcId) && deps.has(tgtId)) return "#58a6ff55";
        if (dependents.has(srcId) && dependents.has(tgtId)) return "#d2992255";
        return "#30363d22";
      })
      .attr("stroke-width", (d) => {
        if (!hasHighlight) return 1;
        const srcId = d.source.id || d.source;
        const tgtId = d.target.id || d.target;
        if (
          (deps.has(srcId) && tgtId === sel) ||
          (srcId === sel && dependents.has(tgtId))
        )
          return 2;
        return 0.5;
      })
      .attr("marker-end", (d) => {
        if (!hasHighlight) return "url(#arrowhead)";
        const srcId = d.source.id || d.source;
        const tgtId = d.target.id || d.target;
        if (
          (deps.has(srcId) && tgtId === sel) ||
          (srcId === sel && dependents.has(tgtId))
        )
          return "url(#arrowhead-highlight)";
        return "url(#arrowhead)";
      });

    this.labelElements.attr("opacity", (d) => {
      if (!hasHighlight) return 0.6;
      if (d.id === sel || deps.has(d.id) || dependents.has(d.id)) return 1;
      return 0.1;
    });
  },

  drag() {
    const simulation = () => this.simulation;

    return d3
      .drag()
      .on("start", (event, d) => {
        if (!event.active) simulation().alphaTarget(0.3).restart();
        d.fx = d.x;
        d.fy = d.y;
      })
      .on("drag", (event, d) => {
        d.fx = event.x;
        d.fy = event.y;
      })
      .on("end", (event, d) => {
        if (!event.active) simulation().alphaTarget(0);
        d.fx = null;
        d.fy = null;
      });
  },
};

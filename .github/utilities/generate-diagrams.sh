#!/usr/bin/env bash
set -euo pipefail

INPUT_DIR="${1:?Input directory required}"
OUTPUT_DIR="${2:-flow-diagrams}"

mkdir -p "$OUTPUT_DIR"

LANE_WIDTH=260
ROW_HEIGHT=140

sanitize_filename() {
  echo "$1" | sed 's#[^a-zA-Z0-9._-]#_#g'
}

get_flow_name() {
  local xml_file="$1"
  xmlstarlet sel -t -v "//*[local-name()='Name']" "$xml_file" 2>/dev/null || echo "Unnamed_Flow"
}

for json in "$INPUT_DIR"/*.json; do

  base=$(basename "$json" .json)
  xml="$INPUT_DIR/$base.json.data.xml"

  if [[ ! -f "$xml" ]]; then
    echo "No XML for $json, skipping"
    continue
  fi

  FLOW_NAME=$(get_flow_name "$xml")
  SAFE_NAME=$(sanitize_filename "$FLOW_NAME")

  OUTPUT_XML="$OUTPUT_DIR/${SAFE_NAME}.drawio"

  echo "🧩 Processing: $FLOW_NAME"

  node_id=1
  edge_id=1000

  declare -A NODE_IDS
  declare -A NODE_LANE
  declare -A NODE_DEPTH

  new_node_id() { echo "n$((node_id++))"; }
  new_edge_id() { echo "e$((edge_id++))"; }

  # ---------- STYLE ----------
  get_style() {
    local type="$1"
    local connector="$2"

    if [[ "$type" == "Scope" ]]; then
      echo "shape=swimlane;strokeColor=#8B4513;fillColor=none;"
      return
    fi

    case "$connector" in
      *sharepoint*) echo "rounded=1;fillColor=#008080;fontColor=#ffffff;" ;;
      *outlook*|*mail*) echo "rounded=1;fillColor=#add8e6;" ;;
      *powerbi*) echo "rounded=1;fillColor=#b8860b;" ;;
      *excel*) echo "rounded=1;fillColor=#90ee90;" ;;
      *powerapps*) echo "rounded=1;fillColor=#800080;fontColor=#ffffff;" ;;
      *dataverse*) echo "rounded=1;fillColor=#006400;fontColor=#ffffff;" ;;
      *office365*) echo "rounded=1;fillColor=#4682b4;fontColor=#ffffff;" ;;
      *) echo "rounded=1;" ;;
    esac
  }

  # ---------- XML START ----------
  cat <<EOF > "$OUTPUT_XML"
<mxfile host="app.diagrams.net">
  <diagram name="$FLOW_NAME">
    <mxGraphModel dx="2000" dy="2000" grid="1" gridSize="10">
      <root>
        <mxCell id="0"/>
        <mxCell id="1" parent="0"/>
EOF

  actions=$(jq -r '.properties.definition.actions | keys[]' "$json")

  lane=0

  # ---------- CREATE NODES ----------
  for action in $actions; do
    id=$(new_node_id)
    NODE_IDS["$action"]="$id"
    NODE_LANE["$action"]=$lane
    NODE_DEPTH["$action"]=0
    lane=$((lane+1))
  done

  create_node() {
    local id="$1" label="$2" lane="$3" depth="$4" style="$5"
    local x=$((lane * LANE_WIDTH + 100))
    local y=$((depth * ROW_HEIGHT + 100))

    cat <<EOF >> "$OUTPUT_XML"
<mxCell id="$id" value="$label" style="$style" vertex="1" parent="1">
  <mxGeometry x="$x" y="$y" width="200" height="80" as="geometry"/>
</mxCell>
EOF
  }

  create_edge() {
    local s="$1" t="$2" label="$3" dashed="$4"

    local style="edgeStyle=orthogonalEdgeStyle;"
    [[ "$dashed" == "true" ]] && style="$style dashed=1;strokeColor=#666666;"

    cat <<EOF >> "$OUTPUT_XML"
<mxCell id="$(new_edge_id)" value="$label" style="$style" edge="1" parent="1" source="$s" target="$t">
  <mxGeometry relative="1" as="geometry"/>
</mxCell>
EOF
  }

  # ---------- RENDER ----------
  for action in $actions; do
    type=$(jq -r ".definition.actions.\"$action\".type" "$json")
    connector=$(jq -r ".definition.actions.\"$action\".inputs.host.connection.name // \"\"" "$json")

    style=$(get_style "$type" "$connector")

    label="$action"

    if [[ "$type" == "Foreach" ]]; then
      label="For each: $action"
      style="shape=swimlane;fillColor=#f5f5f5;"
    fi

    create_node "${NODE_IDS[$action]}" "$label" "${NODE_LANE[$action]}" "${NODE_DEPTH[$action]}" "$style"
  done

  # ---------- RUNAFTER EDGES ----------
  for action in $actions; do
    current="${NODE_IDS[$action]}"

    for dep in $(jq -r ".definition.actions.\"$action\".runAfter | keys[]?" "$json"); do
      dep_id="${NODE_IDS[$dep]}"
      cond=$(jq -r ".definition.actions.\"$action\".runAfter.\"$dep\"[]" "$json")

      create_edge "$dep_id" "$current" "$cond" "true"

      NODE_DEPTH["$action"]=$((NODE_DEPTH[$dep] + 1))
    done
  done

  # ---------- CLOSE ----------
  cat <<EOF >> "$OUTPUT_XML"
      </root>
    </mxGraphModel>
  </diagram>
</mxfile>
EOF

  echo "Created: $OUTPUT_XML"

done

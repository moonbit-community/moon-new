///|
// serde_yaml decodes scalars according to the destination field type. Keep
// their text, style and tag until then; its generic Value loader loses spelling.
priv enum PolicyYamlNode {
  Scalar(String, @yaml.TScalarStyle, @yaml.Tag?)
  Sequence(Array[PolicyYamlNode])
  Mapping(Array[(String, PolicyYamlNode)])
}

///|
priv struct PolicyYamlParser {
  events : Array[@yaml.Event]
  mut index : Int32
  anchors : Map[Int32, PolicyYamlNode]
}

///|
impl @yaml.MarkedEventReceiver for PolicyYamlParser with fn on_event(
  self,
  event,
  _,
) {
  self.events.push(event)
}

///|
fn PolicyYamlParser::node(self : PolicyYamlParser) -> PolicyYamlNode raise {
  guard self.events.get(self.index) is Some(event) else {
    raise Failure("incomplete YAML policy")
  }
  self.index += 1
  let (node, anchor) = match event {
    Scalar(value~, style~, id~, tag~) => (Scalar(value, style, tag), id)
    Alias(id~) => {
      guard self.anchors.get(id) is Some(node) else {
        raise Failure("recursive or unknown YAML policy alias")
      }
      return node
    }
    SequenceStart(id~, ..) => {
      let values = []
      while !(self.events.get(self.index) is Some(SequenceEnd)) {
        values.push(self.node())
      }
      self.index += 1
      (Sequence(values), id)
    }
    MappingStart(id~, ..) => {
      let fields = []
      while !(self.events.get(self.index) is Some(MappingEnd)) {
        guard self.node() is Scalar(key, _, _) else {
          raise Failure("YAML policy keys must be scalars")
        }
        fields.push((key, self.node()))
      }
      self.index += 1
      (Mapping(fields), id)
    }
    _ => raise Failure("expected a YAML policy value")
  }
  if anchor > 0 {
    self.anchors[anchor] = node
  }
  node
}

///|
priv enum PolicyYamlType {
  Record(String, optional~ : Bool)
  Text
  Flag
  List(PolicyYamlType)
  Dictionary
  Ignored
}

///|
fn PolicyYamlNode::fields(
  self : PolicyYamlNode,
) -> Array[(String, PolicyYamlNode)] raise {
  match self {
    Mapping(fields) => fields
    Scalar("", Plain, _) => []
    _ => raise Failure("expected a YAML policy mapping")
  }
}

///|
fn PolicyYamlNode::decode(
  self : PolicyYamlNode,
  expected : PolicyYamlType,
) -> Json raise {
  match expected {
    Ignored => Json::null()
    Text => {
      guard self is Scalar(text, _, _) else {
        raise Failure("expected a YAML policy string")
      }
      Json::string(text)
    }
    Flag => {
      guard self is Scalar(text, style, tag) &&
        (
          style is Plain ||
          (
            style is Literal &&
            tag is Some({ handle: "tag:yaml.org,2002:", suffix: "bool", })
          )
        ) else {
        raise Failure("expected a YAML policy boolean")
      }
      match text {
        "true" | "True" | "TRUE" => Json::boolean(true)
        "false" | "False" | "FALSE" => Json::boolean(false)
        _ => raise Failure("expected a YAML policy boolean")
      }
    }
    List(element) => {
      if self is Scalar("", Plain, _) {
        return Json::array([])
      }
      guard self is Sequence(values) else {
        raise Failure("expected a YAML policy sequence")
      }
      Json::array(values.map(value => value.decode(element)))
    }
    Dictionary => {
      let result = Map([])
      for (key, value) in self.fields() {
        result[key] = value.decode(Text)
      }
      Json::object(result)
    }
    Record(name, optional~) => {
      if optional && self is Scalar(text, Plain, tag) {
        let null = text is ("null" | "Null" | "NULL" | "~")
        match tag {
          None if null || text.is_empty() => return Json::null()
          Some({ handle: "tag:yaml.org,2002:", suffix: "null", }) => {
            guard null else { raise Failure("invalid YAML null") }
            return Json::null()
          }
          _ => ()
        }
      }
      let result = Map([])
      for (key, value) in self.fields() {
        guard !result.contains(key) else {
          raise Failure("duplicate policy field: \{key}")
        }
        let field = match (name, key) {
          ("policy", "fs" | "net" | "env" | "process") =>
            Record(key, optional=true)
          ("fs", "read" | "write")
          | ("net", "dns" | "connect" | "bind")
          | ("env", "from_host" | "required_from_host") => List(Text)
          ("env", "set") => Dictionary
          ("process", "spawn") => Flag
          ("process", "allow") => List(Record("rule", optional=false))
          ("rule", "program") => Text
          ("rule", "args_prefix") => List(Text)
          _ => Ignored
        }
        result[key] = value.decode(field)
      }
      Json::object(result)
    }
  }
}

///|
fn parse_policy_yaml(source : String) -> Json raise {
  let nodes = PolicyYamlParser::{ events: [], index: 0, anchors: {}, }
  let parser = @yaml.Parser(source)
  parser.keep_tags(true)
  parser.load(nodes, true)
  guard nodes.events is [StreamStart, DocumentStart, ..] else {
    raise Failure("expected a YAML policy document")
  }
  nodes.index = 2
  let document = nodes.node()
  guard nodes.events.get(nodes.index) is Some(DocumentEnd) &&
    nodes.events.get(nodes.index + 1) is Some(StreamEnd) &&
    nodes.index + 2 == nodes.events.length() else {
    raise Failure("expected one YAML policy document")
  }
  let fields = document.fields().filter(pair => pair.0 == "policy")
  guard fields is [(_, policy)] else {
    raise Failure("expected one policy in YAML front matter")
  }
  policy.decode(Record("policy", optional=false))
}

///|
async fn main {
  let command = @argparse.Command(
    "moon-new",
    about="Create a MoonBit project from the default template or a Git repository.",
    flags=[
      @argparse.FlagArg(
        "quiet",
        short='q',
        long="quiet",
        about="Hide success output",
      ),
    ],
    options=[
      @argparse.OptionArg(
        "template",
        long="template",
        about="Public HTTPS URL, local Git repository, or GitHub owner/repo",
      ),
      @argparse.OptionArg(
        "subdir",
        long="subdir",
        about="Template subdirectory within the repository",
      ),
      @argparse.OptionArg("branch", long="branch", about="Select a branch"),
      @argparse.OptionArg("tag", long="tag", about="Select a tag"),
      @argparse.OptionArg("rev", long="rev", about="Select a full commit hash"),
      @argparse.OptionArg("user", long="user", about="Module username"),
      @argparse.OptionArg("name", long="name", about="Project name"),
    ],
    positionals=[
      @argparse.PositionArg("PATH", num_args=@argparse.ValueRange::single()),
    ],
  )
  let matches = command.parse() catch {
    error => {
      @stdio.stderr.write("Error: \{error}\n")
      @sys.exit(2)
      return
    }
  }
  let destination = matches.values["PATH"][0]
  let user = matches.values.get("user").map(values => values[0])
  let name = matches.values.get("name").map(values => values[0])
  let template = matches.values.get("template").map(values => values[0])
  let subdir = matches.values.get("subdir").map(values => values[0])
  let branch = matches.values.get("branch").map(values => values[0])
  let tag = matches.values.get("tag").map(values => values[0])
  let rev = matches.values.get("rev").map(values => values[0])
  let selectors = [branch, tag, rev].filter(value => value is Some(_)).length()
  if selectors > 1 || (template is None && (selectors > 0 || subdir is Some(_))) {
    @stdio.stderr.write(
      "Error: --branch, --tag and --rev are mutually exclusive; repository options require --template\n",
    )
    @sys.exit(2)
    return
  }
  let quiet = matches.flags.get("quiet").unwrap_or(false)
  let warnings : Array[String] = []
  let result = Ok(
    @project.create(
      destination,
      user?,
      name?,
      template?,
      subdir?,
      branch?,
      tag?,
      rev?,
      warnings~,
    ),
  ) catch {
    error => Err(error)
  }
  for warning in warnings {
    @stdio.stderr.write("Warning: \{warning}\n")
  }
  let result = match result {
    Ok(project) => project
    Err(error) => {
      match error {
        @os_error.OSError(_) =>
          @stdio.stderr.write(
            "Error: Could not create project at \{destination}.\nCaused by: \{error}\n",
          )
        _ => @stdio.stderr.write("Error: \{error}\n")
      }
      @sys.exit(1)
      return
    }
  }
  if !quiet {
    if result.git_initialized {
      @stdio.stdout.write(
        "Initialized empty Git repository in \{destination}/.git/\n",
      )
    }
    @stdio.stdout.write(
      "Created \{result.username}/\{result.name} at \{destination}\n",
    )
  }
}

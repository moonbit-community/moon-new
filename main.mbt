///|
async fn main {
  let command = @argparse.Command(
    "moon-new",
    about="Create a MoonBit project from the bundled default template.",
    flags=[
      @argparse.FlagArg(
        "quiet",
        short='q',
        long="quiet",
        about="Hide success output",
      ),
    ],
    options=[
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
  let quiet = matches.flags.get("quiet").unwrap_or(false)
  let warnings : Array[String] = []
  let result = @project.create(destination, user?, name?, warnings~) catch {
    error => {
      for warning in warnings {
        @stdio.stderr.write("Warning: \{warning}\n")
      }
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
  for warning in result.warnings {
    @stdio.stderr.write("Warning: \{warning}\n")
  }
  if !quiet {
    @stdio.stdout.write(result.git_stdout)
    @stdio.stderr.write(result.git_stderr)
    @stdio.stdout.write(
      "Created \{result.username}/\{result.name} at \{destination}\n",
    )
  }
}

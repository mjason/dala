if (-not (Test-Path variable:global:DalaOriginalPrompt)) {
  $global:DalaOriginalPrompt = $function:prompt
}

function global:prompt {
  try {
    $location = $executionContext.SessionState.Path.CurrentFileSystemLocation.Path
    $uri = [System.Uri]::new($location).AbsoluteUri
    [Console]::Write("$([char]27)]7;$uri$([char]7)")
  } catch {
    # Non-filesystem providers do not have a directory for Dala to follow.
  }

  if ($global:DalaOriginalPrompt) {
    & $global:DalaOriginalPrompt
  } else {
    "PS $($executionContext.SessionState.Path.CurrentLocation)> "
  }
}

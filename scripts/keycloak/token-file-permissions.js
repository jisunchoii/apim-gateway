import { execFileSync } from "node:child_process"
import { chmod } from "node:fs/promises"
import { join } from "node:path"

export const hardenTokenFile = async (path) => {
  if (process.platform === "win32") {
    const system32 = join(
      process.env.SystemRoot || "C:\\Windows",
      "System32",
    )
    const userDetails = execFileSync(
      join(system32, "whoami.exe"),
      ["/user", "/fo", "csv", "/nh"],
      {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
      },
    )
    const sid = userDetails.match(/S-\d+(?:-\d+)+/)?.[0]
    if (!sid) {
      throw new Error("Could not determine the current Windows user SID.")
    }

    execFileSync(
      join(system32, "icacls.exe"),
      [path, "/inheritance:r", "/grant:r", `*${sid}:(F)`],
      { stdio: "ignore" },
    )
    return
  }

  await chmod(path, 0o600)
}

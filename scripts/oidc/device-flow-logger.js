import { spawn } from "node:child_process"

const browserCommand = (platform, url) =>
  platform === "win32"
    ? ["rundll32.exe", ["url.dll,FileProtocolHandler", url]]
    : platform === "darwin"
      ? ["open", [url]]
      : ["xdg-open", [url]]

export const createDeviceFlowLogger = ({
  openBrowser = false,
  logger = (message) => console.error(message),
  platform = process.platform,
  env = process.env,
  spawnImpl = spawn,
} = {}) => {
  let openedVerificationUrl = false

  return (message) => {
    logger(message)
    if (!openBrowser || openedVerificationUrl) return

    const verificationUrl = message.match(/https?:\/\/\S+/)?.[0]
    if (!verificationUrl) return

    openedVerificationUrl = true
    if (
      platform === "linux" &&
      !env.DISPLAY?.trim() &&
      !env.WAYLAND_DISPLAY?.trim()
    ) {
      logger(
        "그래픽 브라우저를 사용할 수 없습니다. 위 주소를 다른 PC의 브라우저에서 직접 여세요.",
      )
      return
    }

    const [command, args] = browserCommand(platform, verificationUrl)
    const child = spawnImpl(command, args, {
      detached: true,
      stdio: "ignore",
      windowsHide: true,
    })
    child.on("error", (error) => {
      logger(
        `브라우저를 자동으로 열지 못했습니다: ${error.message}. 위 주소를 직접 여세요.`,
      )
    })
    child.on("exit", (code, signal) => {
      if (code === 0 && !signal) return
      const detail = signal ? `signal ${signal}` : `exit code ${code}`
      logger(
        `브라우저를 자동으로 열지 못했습니다 (${detail}). 위 주소를 직접 여세요.`,
      )
    })
    child.unref()
  }
}

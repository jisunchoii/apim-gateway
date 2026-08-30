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
  spawnImpl = spawn,
} = {}) => {
  let openedVerificationUrl = false

  return (message) => {
    logger(message)
    if (!openBrowser || openedVerificationUrl) return

    const verificationUrl = message.match(/https?:\/\/\S+/)?.[0]
    if (!verificationUrl) return

    openedVerificationUrl = true
    const [command, args] = browserCommand(platform, verificationUrl)
    const child = spawnImpl(command, args, {
      detached: true,
      stdio: "ignore",
      windowsHide: true,
    })
    child.on("error", (error) => {
      logger(`브라우저를 자동으로 열지 못했습니다: ${error.message}`)
    })
    child.unref()
  }
}

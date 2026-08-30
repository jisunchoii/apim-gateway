#!/usr/bin/env node

import { fileURLToPath } from "node:url"
import { resolve } from "node:path"
import {
  configure,
  main as startClaude,
  validatePrerequisites,
} from "../okta/claude.js"
import {
  collectDoctorReport,
  formatDoctorReport,
} from "../okta/doctor.js"
import { main as stopClaudeRuntime } from "../okta/down.js"

export const usage = `Usage: npm run claude -- [command] [claude-args...]

Commands:
  start       Configure and launch Claude Code (default)
  configure   Write the dedicated OpenCodex profile and Claude settings
  doctor      Check Node, Claude CLI, OpenCodex, config, and local services
  restart     Stop local services and launch Claude Code
  down        Stop OpenCodex and the auth proxy

Examples:
  npm run claude
  npm run claude -- configure
  npm run claude -- doctor
  npm run claude -- restart
  npm run claude -- down
  npm run claude -- start --resume
`

const knownCommands = new Set([
  "start",
  "configure",
  "doctor",
  "restart",
  "down",
  "help",
])

export const parseClaudeArgv = (argv = []) => {
  const args = [...argv]
  if (args.includes("--help") || args.includes("-h") || args[0] === "help") {
    return { command: "help", extraArgs: [] }
  }
  if (args.includes("--configure")) {
    return {
      command: "configure",
      extraArgs: args.filter((argument) => argument !== "--configure"),
    }
  }
  if (args[0] && !args[0].startsWith("-")) {
    if (!knownCommands.has(args[0])) {
      throw new Error(`Unknown command: ${args[0]}\n${usage}`)
    }
    return { command: args[0], extraArgs: args.slice(1) }
  }
  return { command: "start", extraArgs: args }
}

const printConfigure = (setup, settingsPath, write) => {
  write(
    [
      `OpenCodex config: ${setup.configPath}`,
      `Claude Code settings: ${settingsPath}`,
      `Responses models: ${setup.modelConfig.responsesModels.join(", ") || "(none)"}`,
      `Chat models: ${setup.modelConfig.chatModels.join(", ") || "(none)"}`,
      `Default model: ${setup.modelConfig.defaultModel}`,
    ].join("\n") + "\n",
  )
}

export const runClaudeCli = async (
  argv,
  {
    start = startClaude,
    configureImpl = configure,
    doctor = collectDoctorReport,
    formatDoctor = formatDoctorReport,
    down = stopClaudeRuntime,
    validate = validatePrerequisites,
    stdout = (message) => process.stdout.write(message),
  } = {},
) => {
  const { command, extraArgs } = parseClaudeArgv(argv)
  if (command === "help") {
    stdout(`${usage}\n`)
    return 0
  }
  if (command === "configure") {
    validate()
    const { setup, settingsPath } = await configureImpl()
    printConfigure(setup, settingsPath, stdout)
    return 0
  }
  if (command === "doctor") {
    const report = await doctor()
    stdout(`${formatDoctor(report)}\n`)
    return report.ok ? 0 : 1
  }
  if (command === "down") {
    await down()
    return 0
  }
  if (command === "restart") {
    await down()
    await start({ extraArgs })
    return 0
  }
  await start({ extraArgs })
  return 0
}

const isMain =
  process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)

if (isMain) {
  try {
    process.exitCode = await runClaudeCli(process.argv.slice(2))
  } catch (error) {
    process.stderr.write(`${error.message}\n`)
    process.exitCode = 1
  }
}

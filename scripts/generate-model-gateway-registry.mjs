import { readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const BEGIN_MARKER = "<!-- BEGIN_TERRAFORM_CATALOG -->";
const END_MARKER = "<!-- END_TERRAFORM_CATALOG -->";

function parseArgs(argv) {
  const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
  const repoRoot = path.resolve(scriptDirectory, "..");
  const options = {
    terraformDirectory: path.join(repoRoot, "infra"),
    htmlPath: path.join(repoRoot, "docs", "model-gateway-registry.html"),
    templatePath: null
  };

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--terraform-dir") {
      options.terraformDirectory = path.resolve(argv[++index]);
    } else if (argument === "--html") {
      options.htmlPath = path.resolve(argv[++index]);
    } else if (argument === "--template-html") {
      options.templatePath = path.resolve(argv[++index]);
    } else {
      throw new Error(`Unknown argument: ${argument}`);
    }
  }
  return options;
}

function readTerraformManifest(terraformDirectory) {
  const result = spawnSync(
    "terraform",
    [`-chdir=${terraformDirectory}`, "output", "-json", "api_catalog_manifest"],
    { encoding: "utf8", shell: false }
  );

  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(result.stderr.trim() || "terraform output api_catalog_manifest failed");
  }

  const manifest = JSON.parse(result.stdout);
  if (manifest?.schema_version !== 1 || !manifest.gateway || !Array.isArray(manifest.models)) {
    throw new Error("api_catalog_manifest does not match schema version 1");
  }
  if (
    manifest.gateway.generation === "claude-standard-v2" &&
    (manifest.models.length !== 0 || !manifest.gateway.claude_models)
  ) {
    throw new Error(
      "claude-standard-v2 manifest must contain claude_models and no OpenAI/Fireworks model rows"
    );
  }
  return manifest;
}

function renderCatalogBlock(manifest) {
  const generatedManifest = {
    ...manifest,
    generated_at: new Date().toISOString()
  };
  const json = JSON.stringify(generatedManifest, null, 2)
    .replaceAll("<", "\\u003c")
    .replaceAll("\u2028", "\\u2028")
    .replaceAll("\u2029", "\\u2029");
  const indentedJson = json.split("\n").map((line) => `      ${line}`).join("\n");

  return [
    `    ${BEGIN_MARKER}`,
    "    <script id=\"terraform-api-catalog\">",
    `      window.__TERRAFORM_CATALOG__ =`,
    indentedJson + ";",
    "    </script>",
    `    ${END_MARKER}`
  ].join("\n");
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const manifest = readTerraformManifest(options.terraformDirectory);
  const sourcePath = options.templatePath || options.htmlPath;
  const html = await readFile(sourcePath, "utf8");
  const markerPattern = new RegExp(
    `\\s*${BEGIN_MARKER}[\\s\\S]*?${END_MARKER}`
  );

  if (!markerPattern.test(html)) {
    throw new Error(`Terraform catalog markers are missing from ${sourcePath}`);
  }

  const updated = html.replace(markerPattern, `\n${renderCatalogBlock(manifest)}`);
  const temporaryPath = `${options.htmlPath}.${process.pid}.tmp`;
  await writeFile(temporaryPath, updated, "utf8");
  await rename(temporaryPath, options.htmlPath);
  process.stdout.write(
    `Updated ${options.htmlPath} with ${manifest.models.length} Terraform-routed models.\n`
  );
}

main().catch((error) => {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
});

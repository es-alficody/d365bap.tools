const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { withSignatureDeltaSession, DELTA_SCRIPT } = require('./signature-delta-session.cjs');

// Real Git objects, deliberately including code which must never be executed.
test('compares public and SDK signature inputs as data', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'signature-inputs-'));
  const git = (...args) => execFileSync('git', args, { cwd: directory, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  const files = {
    'd365bap.tools/d365bap.tools.psd1': '@{ RootModule = "main.psm1"; FunctionsToExport = @("Get-Example"); CmdletsToExport = @(); AliasesToExport = @(); VariablesToExport = @() }',
    'd365bap.tools/functions/Get-Example.ps1': 'function Get-Example { [CmdletBinding(DefaultParameterSetName="One")] param([Alias("Old")][string]$Name = "default") process { throw "must not execute" } }',
    'd365bap.tools/d365bap.tools.psm1': 'throw "must not execute"; . "$PSScriptRoot/functions/Get-Example.ps1"',
    'd365bap.tools/internal/scripts/preimport.ps1': '"preload.ps1"',
    'd365bap.tools/internal/scripts/postimport.ps1': '"initialize-sdk.ps1"',
    'd365bap.tools/internal/sdk/commands.psd1': '@{ Resources = @(@{ Noun = "Example"; Builder = "A"; Methods = @{ Get = "GetAsync" }; Scope = "Tenant" }) }',
    'd365bap.tools/internal/scripts/initialize-sdk.ps1': 'throw "must not execute"; $parameterDefinition = "[string]$Name"',
    'd365bap.tools/internal/sdk/runtime.ps1': 'function Import-BapSdk { throw "must not execute"; $bridge = "Sdk.dll" }\nfunction Get-BapSdkParameter { throw "must not execute"; $name = $Resource.ParameterPrefix }\nfunction Invoke-Other { "body" }',
    'library/PowerPlatformSdk/PowerPlatformSdk.csproj': '<Project><PackageReference Include="Microsoft.PowerPlatform.Management" Version="1" /></Project>',
    'library/PowerPlatformSdk/SdkClient.cs': 'class SdkClient {}',
    'd365bap.tools/bin/PowerPlatformSdk/Microsoft.PowerPlatform.Management.dll': Buffer.from([0, 1, 2, 255]),
    'd365bap.tools/bin/PowerPlatformSdk/D365Bap.Tools.PowerPlatformSdk.dll': Buffer.from([0, 2, 3, 255]),
  };
  const write = (name, content) => {
    const target = path.join(directory, name);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, content);
  };
  const commit = () => { git('add', '-A'); git('commit', '-qm', 'fixture'); };
  try {
    git('init', '-q'); git('config', 'user.name', 'Fixture'); git('config', 'user.email', 'fixture@example.test');
    git('config', 'core.autocrlf', 'false'); git('config', 'core.quotePath', 'true'); git('config', 'commit.gpgsign', 'false');
    for (const [name, content] of Object.entries(files)) write(name, content);
    commit();
    const base = git('rev-parse', 'HEAD');

    // One end-to-end subprocess invocation, kept as the contract check for the
    // real command line, real exit code and real stdout encoding.
    const direct = () => execFileSync('pwsh', ['-NoProfile', '-NonInteractive', '-File', DELTA_SCRIPT, '-BaseRef', base, '-HeadRef', 'HEAD'], { cwd: directory, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    assert.deepEqual(JSON.parse(direct()).changes, [], 'unchanged fixture reports no declaration change and exits zero');

    await withSignatureDeltaSession(directory, async session => {
      const compare = async (baseRef = base) => (await session.request(baseRef, 'HEAD')).changes;
      const changed = async (file, content, expected) => {
        for (const [name, original] of Object.entries(files)) write(name, original);
        write(file, content); commit();
        const result = await compare();
        assert.equal(result.length, 1, `${file}: ${JSON.stringify(result)}`);
        assert.match(result[0].name, expected);
      };
      const command = 'd365bap.tools/functions/Get-Example.ps1';
      await changed(command, files[command].replace('DefaultParameterSetName="One"', 'DefaultParameterSetName="Two"'), /Get-Example/);
      await changed(command, files[command].replace('Alias("Old")', 'Alias("New")'), /Get-Example/);
      await changed(command, files[command].replace('"default"', '"changed"'), /Get-Example/);
      await changed(command, files[command].replace('process {', 'dynamicparam { throw "must not execute" } process {'), /Get-Example/);
      await changed(command, `${files[command]}\nSet-Alias ExampleAlias Get-Example`, /<top-level>/);
      await changed(command, `param([int]$ScriptOption)\n${files[command]}`, /<top-level>/);
      const manifest = 'd365bap.tools/d365bap.tools.psd1';
      await changed(manifest, files[manifest].replace('VariablesToExport = @()', 'VariablesToExport = @("Public")'), /manifest\/VariablesToExport/);
      await changed(manifest, files[manifest].replace('RootModule = "main.psm1"', 'RootModule = "other.psm1"'), /manifest\/RootModule/);
      for (const loader of ['d365bap.tools/d365bap.tools.psm1', 'd365bap.tools/internal/scripts/preimport.ps1', 'd365bap.tools/internal/scripts/postimport.ps1']) {
        await changed(loader, `${files[loader]}\n"other.ps1"`, /loader\//);
      }
      const mapping = 'd365bap.tools/internal/sdk/commands.psd1';
      await changed(mapping, files[mapping].replace('Builder = "A"', 'Builder = "B"'), /sdk\/.*commands\.psd1/);
      await changed(mapping, files[mapping].replace('GetAsync', 'OtherAsync'), /sdk\/.*commands\.psd1/);
      const generator = 'd365bap.tools/internal/scripts/initialize-sdk.ps1';
      await changed(generator, files[generator].replace('[string]$Name', '[switch]$Name'), /sdk\/.*initialize-sdk/);
      await changed(generator, files['d365bap.tools/internal/scripts/preimport.ps1'], /sdk\/.*initialize-sdk/);
      const runtime = 'd365bap.tools/internal/sdk/runtime.ps1';
      await changed(runtime, files[runtime].replace('$Resource.ParameterPrefix', '$Resource.OtherPrefix'), /sdk\/.*Get-BapSdkParameter/);
      await changed(runtime, files[runtime].replace('Sdk.dll', 'Other.dll'), /sdk\/.*Import-BapSdk/);
      const project = 'library/PowerPlatformSdk/PowerPlatformSdk.csproj';
      await changed(project, files[project].replace('Version="1"', 'Version="2"'), /sdk\/.*csproj/);
      const binary = 'd365bap.tools/bin/PowerPlatformSdk/Microsoft.PowerPlatform.Management.dll';
      await changed(binary, Buffer.from([0, 1, 3, 255]), /sdk\/.*\.dll/);
      const bridge = 'library/PowerPlatformSdk/SdkClient.cs';
      await changed(bridge, files[bridge].replace('SdkClient', 'OtherClient'), /sdk\/.*SdkClient\.cs/);
      const bridgeBinary = 'd365bap.tools/bin/PowerPlatformSdk/D365Bap.Tools.PowerPlatformSdk.dll';
      await changed(bridgeBinary, Buffer.from([0, 1, 3, 255]), /sdk\/.*PowerPlatformSdk\.dll/);

      for (const [name, original] of Object.entries(files)) write(name, original);
      write(runtime, files[runtime].replace('function Invoke-Other { "body" }', 'function Invoke-Other { "changed" }'));
      commit(); assert.deepEqual(await compare(), [], 'unrelated runtime body is ignored');
      write(runtime, files[runtime]);
      write('unrelated.txt', 'unrelated'); commit();
      assert.deepEqual(await compare(), [], 'unrelated files do not change declarations');
      const renamed = 'd365bap.tools/functions/Get-Renamed.ps1';
      fs.renameSync(path.join(directory, command), path.join(directory, renamed)); commit();
      const renameChanges = await compare();
      assert.equal(renameChanges.length, 2, 'rename records both removal and addition');
      assert.ok(renameChanges.some(change => change.name.includes('Get-Example.ps1') && change.after === null));
      assert.ok(renameChanges.some(change => change.name.includes('Get-Renamed.ps1') && change.before === null));
      fs.renameSync(path.join(directory, renamed), path.join(directory, command));
      fs.unlinkSync(path.join(directory, command)); commit();
      assert.equal((await compare())[0].after, null, 'deletion is recorded');
      write(command, files[command]);
      git('add', command);
      const objectId = git('hash-object', path.join(directory, command));
      git('update-index', '--cacheinfo', `120000,${objectId},${command}`);
      git('commit', '-qm', 'symlink fixture');
      // Real subprocess fail-closed contract: non-zero exit, no JSON on stdout.
      assert.throws(direct, /Unsupported Git file mode/, 'symlinks fail closed in a real subprocess');
      await assert.rejects(compare(), /Unsupported Git file mode/, 'symlinks fail closed');
      git('reset', '-q', 'HEAD^');
      write(command, files[command]);
      git('add', command);
      git('update-index', '--add', '--cacheinfo', `100644,${objectId},d365bap.tools/functions/get-Example.ps1`);
      git('commit', '-qm', 'case collision fixture');
      await assert.rejects(compare(), /Case-insensitive Git path collision/, 'case collisions fail closed');
      git('reset', '-q', 'HEAD^');
      write(command, files[command]);
      fs.unlinkSync(path.join(directory, binary)); commit();
      await assert.rejects(compare(), /Missing SDK signature input/, 'incomplete SDK fails closed');
      write(binary, files[binary]);
      write(runtime, 'function Other { }'); commit();
      await assert.rejects(compare(), /Expected one SDK parameter generator/, 'missing generator fails closed');
      write(runtime, files[runtime]);
      write(mapping, '@{ Resources = @('); commit();
      await assert.rejects(compare(), /Cannot parse/, 'invalid SDK source fails closed');
      await assert.rejects(compare('HEAD'), /Cannot parse/, 'unchanged malformed input fails closed');
      write(mapping, files[mapping]);
      write(manifest, `function Decoy { @{ FunctionsToExport = @() } }\n${files[manifest]}`); commit();
      await assert.rejects(compare(), /Expected a literal module manifest/, 'nested decoy manifest fails closed');
      write(manifest, files[manifest]);
      write('d365bap.tools/functions/Get-Éxample.ps1', 'function Get-Example { param() }'); commit();
      await assert.rejects(compare(), /Unsupported quoted Git path/, 'quoted paths fail closed rather than being skipped');
    });
  } finally {
    assert.equal(path.dirname(directory), os.tmpdir());
    assert.ok(path.basename(directory).startsWith('signature-inputs-'));
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

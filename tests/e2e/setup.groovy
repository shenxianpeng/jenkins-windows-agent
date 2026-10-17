// Jenkins init script for the end-to-end tests: creates one inbound agent and
// a freestyle job pinned to it, then writes the agent secret to a file so the
// test can pick it up. Works on Jenkins 2.346.x up to current releases.
import hudson.model.FreeStyleProject
import hudson.model.Node
import hudson.security.FullControlOnceLoggedInAuthorizationStrategy
import hudson.security.HudsonPrivateSecurityRealm
import hudson.slaves.DumbSlave
import hudson.slaves.JNLPLauncher
import hudson.slaves.RetentionStrategy
import hudson.tasks.BatchFile
import jenkins.model.Jenkins
import jenkins.model.JenkinsLocationConfiguration

def env = System.getenv()
def jenkins = Jenkins.get()
def webSocket = env['E2E_WEBSOCKET'] == 'true'

jenkins.setNumExecutors(0)
// WebSocket runs disable the TCP port, so they only pass over WebSocket.
jenkins.setSlaveAgentPort(webSocket ? -1 : 50000)
JenkinsLocationConfiguration.get().setUrl(env['E2E_JENKINS_URL'])

if (env['E2E_SECURED'] == 'true') {
    def realm = new HudsonPrivateSecurityRealm(false)
    realm.createAccount(env['E2E_ADMIN_USER'], env['E2E_ADMIN_PASSWORD'])
    jenkins.setSecurityRealm(realm)
    def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
    strategy.setAllowAnonymousRead(false)
    jenkins.setAuthorizationStrategy(strategy)
}

def launcher = new JNLPLauncher(true)
if (webSocket) {
    launcher.setWebSocket(true)
}
def agent = new DumbSlave(env['E2E_AGENT_NAME'], env['E2E_REMOTE_FS'], launcher)
agent.setNumExecutors(1)
agent.setLabelString('windows e2e')
agent.setMode(Node.Mode.EXCLUSIVE)
agent.setRetentionStrategy(new RetentionStrategy.Always())
jenkins.addNode(agent)

def job = jenkins.createProject(FreeStyleProject, 'smoke')
job.setAssignedLabel(jenkins.getLabel('e2e'))
job.getBuildersList().add(new BatchFile('@echo off\r\necho E2E-MARKER node=%NODE_NAME%\r\nwhoami\r\ncd'))
job.save()
jenkins.save()

def secret = jenkins.getComputer(env['E2E_AGENT_NAME']).getJnlpMac()
new File(env['JENKINS_HOME'], 'e2e-agent-secret.txt').text = secret

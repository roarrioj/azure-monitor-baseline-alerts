# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

<#
.SYNOPSIS
    This script cleans up the alert processing rule and action group created deployed by the ALZ-Monitor automation versions up to 2023-11-14 and not in use anymore.

.DESCRIPTION
    This script cleans up the alert processing rule and action group created deployed by the ALZ-Monitor automation versions up to 2023-11-14 and not in use anymore.
    Newer versions will deploy 1 action group per subscription specific to Service Health alerts and 1 action group, which is member of 1 alert processing rule, per
    subscription for all other alerts

.NOTES
    In order for this script to function the deployed resources must have a tag _deployed_by_amba with a value of true and Policy resources must have metadata property
    named _deployed_by_amba with a value of True. These tags and metadata are included in the automation, but if they are subsequently removed, there may be orphaned
    resources after this script executes.

    This script leverages the Azure Resource Graph to find object to delete. Note that the Resource Graph lags behind ARM by a couple minutes.

.LINK
    https://github.com/Azure/azure-monitor-baseline-alerts

.EXAMPLE
    ./Start-AMBAOldArpCleanup.ps1 -pseudoRootManagementGroup Contoso -WhatIf
    # show output of what would happen if deletes executed.

.EXAMPLE
    ./Start-AMBAOldArpCleanup.ps1 -pseudoRootManagementGroup Contoso
    # execute the script and will ask for confirmation before taking the configured action.

.EXAMPLE
    ./Start-AMBAOldArpCleanup.ps1 -pseudoRootManagementGroup Contoso -Confirm:$false
    # execute the script without asking for confirmation before taking the configured action.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    # the pseudo managemnt group to start from
    [Parameter(Mandatory=$True,
        ValueFromPipeline=$false)]
        [string]$pseudoRootManagementGroup
)

Function Search-AzGraphRecursive {
    # ensure query results with more than 100 resources and/or over more than 10 management groups are returned
    param($query, $managementGroupNames, $skipToken)

    $optionalParams = @{}
    If ($skipToken) {
        $optionalParams += @{skipToken = $skipToken }
    }

    # ARG will only query 10 management groups at a time--implement batching
    If ($managementGroupNames.count -gt 10) {
        $managementGroupBatches = @()

        For ($i=0;$i -le $managementGroupNames.count;$i=$i+10) {
            $batchGroups = $managementGroupNames[$i..($i+9)]
            $managementGroupBatches += ,@($batchGroups)

            If ($batchGroups.count -lt 10) {
                continue
            }
        }

        $result = @()
        ForEach ($managementGroupBatch in $managementGroupBatches) {
            $batchResult = Search-AzGraph -Query $query -ManagementGroup $managementGroupBatch -Verbose:$false @optionalParams

            # resource graph returns pages of 100 resources, if there are more than 100 resources in a batch, recursively query for more
            If ($batchResult.count -eq 100 -and $batchResult.SkipToken) {
                $result += $batchResult
                Search-AzGraphRecursive -query $query -managementGroupNames $managementGroupNames -skipToken $batchResult.SkipToken
            }
            else {
                $result += $batchResult
            }
        }
    }
    Else {
        $result = Search-AzGraph -Query $query -ManagementGroup $managementGroupNames -Verbose:$false @optionalParams

        If ($result.count -eq 100 -and $result.SkipToken) {
            Search-AzGraphRecursive -query $query -managementGroupNames $managementGroupNames -skipToken $result.SkipToken
        }
    }

    $result
}

Function Iterate-ManagementGroups($mg) {

  $script:managementGroups += $mg.Name
  if ($mg.Children) {
      foreach ($child in $mg.Children) {
          if ($child.Type -eq 'Microsoft.Management/managementGroups') {
          Iterate-ManagementGroups $child
          }
      }
  }
}

$ErrorActionPreference = 'Stop'

If (-NOT(Get-Module -ListAvailable Az.ResourceGraph)) {
    Write-Warning "This script requires the Az.ResourceGraph module."

    $response = Read-Host "Would you like to install the 'Az.ResourceGraph' module now? (y/n)"
    If ($response -match '[yY]') { Install-Module Az.ResourceGraph -Scope CurrentUser }
}

# get all management groups -- used in graph query scope
$managementGroups = @()
$allMgs = Get-AzManagementGroup -GroupName $pseudoRootManagementGroup -Expand -Recurse
foreach ($mg in $allMgs) {
    Iterate-ManagementGroups $mg
}

Write-Host "Found '$($managementGroups.Count)' management groups(s) (including the parent one) which are part of the '$pseudoRootManagementGroup' management group hierarchy, to be queried for action groups and alert processing rules deployed by ALZ-Monitor."


If ($managementGroups.count -eq 0) {
    Write-Error "The command 'Get-AzManagementGroups' returned '0' groups. This script needs to run with Owner permissions on the Azure Landing Zones intermediate root management group to effectively remove action groups and alert processing rules deployed by AMBA-ALZ."
    return
}

# get alert processing rules to delete
$query = "resources | where type =~ 'Microsoft.AlertsManagement/actionRules' | where name == 'AMBA Alert Processing Rule' and properties.description == 'AMBA Alert Processing Rule for Subscription' and tags['_deployed_by_amba'] =~ 'True'| project id"
$alertProcessingRuleIds = Search-AzGraphRecursive -Query $query -ManagementGroupNames $managementGroups | Select-Object -ExpandProperty Id | Sort-Object | Get-Unique
Write-Host "Found '$($alertProcessingRuleIds.Count)' alert processing rule(s) with description 'AMBA Alert Processing Rule for Subscription' and tag '_deployed_by_amba=True' to be deleted."

# get action groups to delete
$query = "resources | where type =~ 'Microsoft.Insights/actionGroups' | where name =~ 'AmbaActionGr' and properties.groupShortName =~ 'AmbaActionGr'and tags['_deployed_by_amba'] =~ 'True' | project id"
$actionGroupIds = Search-AzGraphRecursive -Query $query -ManagementGroupNames $managementGroups | Select-Object -ExpandProperty Id | Sort-Object | Get-Unique
Write-Host "Found '$($actionGroupIds.Count)' action group(s) with name 'AmbaActionGr', short name 'AmbaActionGr' and tag '_deployed_by_amba=True' to be deleted."

If (($alertProcessingRuleIds.count -gt 0) -or ($actionGroupIds.count -gt 0)) {
    If ($PSCmdlet.ShouldProcess($pseudoRootManagementGroup, "Delete ALZ-Monitor alert processing rules and action groups on the '$pseudoRootManagementGroup' Management Group hierarchy ..." )) {
        # delete alert processing rules
        If ($alertProcessingRuleIds.count -gt 0) {
          Write-Host "-- Deleting alert processing rules ..."
          $alertProcessingRuleIds | Foreach-Object { Remove-AzResource -ResourceId $_ -Force }
        }

        # delete action groups
        If ($actionGroupIds.count -gt 0) {
          Write-Host "-- Deleting action groups ..."
          $actionGroupIds | Foreach-Object { Remove-AzResource -ResourceId $_ -Force }
        }
    }
}

Write-Host "=== Script execution completed. ==="

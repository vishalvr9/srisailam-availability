[CmdletBinding()]
param(
    [ValidatePattern('^\d{4}-\d{2}-\d{2}$')]
    [string]$Date = '2026-11-14',

    [switch]$Watch,

    [ValidateRange(60, 86400)]
    [int]$IntervalSeconds = 300
)

$ErrorActionPreference = 'Stop'
$targetDate = [datetime]::ParseExact(
    $Date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture
)
$appId = '1DB27F67-8EE2-431C-A120-877E255B6745'

function Invoke-TempleApi {
    param(
        [string]$Endpoint,
        [hashtable]$Fields,
        [string[]]$RequiredFields
    )

    $payload = @{
        temple_id = '0'
        temple_code = 'SSLBMS'
        deviceid = 'T2SNS33.73-22-3-19'
        appversion = '1.0.0'
    }
    foreach ($key in $Fields.Keys) {
        $payload[$key] = $Fields[$key]
    }

    $response = Invoke-RestMethod `
        -Uri "https://tms.ap.gov.in/v2/OnlineServices/$Endpoint" `
        -Method Post `
        -Headers @{ etkn = 'TMSAPTS' } `
        -ContentType 'application/json' `
        -Body ($payload | ConvertTo-Json) `
        -TimeoutSec 30

    if ([string]$response.ResponseStatus -ne 'True') {
        throw "API $Endpoint failed: $($response.ResponseCode) $($response.ResponseMsg)"
    }
    foreach ($field in $RequiredFields) {
        if ($null -eq $response.$field -or $response.$field -isnot [System.Array]) {
            throw "API $Endpoint returned a missing or invalid array: $field"
        }
    }
    return $response
}

function Get-SparshaAvailability {
    $calendar = Invoke-TempleApi -Endpoint 'GetPDarshanCalendar' -Fields @{
        appid = $appId
        darsan_id = '0'
        calStart_date = $targetDate.ToString('yyyy-MM-01')
        calEnd_date = $targetDate.AddMonths(1).AddDays(-$targetDate.Day).ToString('yyyy-MM-dd')
    } -RequiredFields @(
        'AvailableDates', 'QuotaFullDates', 'QuotaNotReleasedDates',
        'DarshanNotPerformedDates'
    )

    $slotsResponse = Invoke-TempleApi -Endpoint 'GetPDarshanSlots' -Fields @{
        app_id = $appId
        darsan_id = '96'
        darsan_slotid = 0
        darsan_date = $Date
    } -RequiredFields @('DarsanSlots')

    $availableSlots = @(
        foreach ($slot in $slotsResponse.DarsanSlots) {
            $count = 0
            if (
                -not [int]::TryParse([string]$slot.darsan_cnt, [ref]$count) -or
                $count -lt 0 -or
                [string]$slot.darsan_id -ne '96' -or
                [string]::IsNullOrWhiteSpace([string]$slot.darsan_starttime) -or
                [string]::IsNullOrWhiteSpace([string]$slot.darsan_endtime)
            ) {
                throw 'The slots API returned an unexpected slot format.'
            }
            if ($count -gt 0) {
                [pscustomobject]@{
                    startTime = $slot.darsan_starttime
                    endTime = $slot.darsan_endtime
                    ticketsLeft = $count
                    price = $slot.darsan_cost
                }
            }
        }
    )

    $calendarStatus = 'date_not_listed'
    $categories = [ordered]@{
        AvailableDates = 'calendar_available'
        QuotaFullDates = 'quota_full'
        QuotaNotReleasedDates = 'quota_not_released'
        DarshanNotPerformedDates = 'darshan_not_performed'
    }
    $matchingCategories = @(
        foreach ($category in $categories.Keys) {
            foreach ($entry in $calendar.$category) {
                $calendarDate = [datetime]::MinValue
                if (-not [datetime]::TryParseExact(
                    [string]$entry.calendar_date,
                    [string[]]@('yyyy/MM/dd', 'yyyy-MM-dd'),
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::None,
                    [ref]$calendarDate
                )) {
                    throw 'The calendar API returned an unexpected date format.'
                }
                if ($calendarDate -eq $targetDate) {
                    $categories[$category]
                }
            }
        }
    )
    if ($matchingCategories.Count -gt 1) {
        throw 'The calendar API returned conflicting statuses for the target date.'
    }
    if ($matchingCategories.Count -eq 1) {
        $calendarStatus = $matchingCategories[0]
    }

    # Calendar availability is shared by darshan types; only positive slot counts confirm tickets.
    $status = 'no_sparsha_slots'
    if ($availableSlots.Count -gt 0) {
        $status = 'available'
    } elseif ($calendarStatus -ne 'calendar_available') {
        $status = $calendarStatus
    }

    [pscustomobject]@{
        checkedAt = [DateTimeOffset]::Now.ToString('o')
        temple = 'SSLBMS'
        date = $Date
        darshan = 'Sparsha Darshanam'
        darshanId = 96
        available = ($availableSlots.Count -gt 0)
        status = $status
        calendarStatus = $calendarStatus
        slots = $availableSlots
        bookingUrl = 'https://tms.ap.gov.in/#/temple-details/SSLBMS?section=darsan'
    }
}

do {
    Get-SparshaAvailability | ConvertTo-Json -Depth 6
    if ($Watch) {
        Start-Sleep -Seconds $IntervalSeconds
    }
} while ($Watch)

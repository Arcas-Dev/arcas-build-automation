# Arcas Champions Phase 2: Player Lobby Implementation Analysis

**Document Purpose**: Comprehensive technical reference for implementing Phase 2 player lobby functionality in Arcas Champions multiplayer infrastructure.

**Source Materials**:
- `MatchmakerComponent.cpp` (1,025 lines) - Core implementation with commented-out Phase 2 patterns
- `multiplayer-infrastructure.md` (880 lines) - Architectural documentation with Phase 2 requirements
- `DedicatedServerBackendSubsystem.cpp` - Group ticket API integration patterns

**Status**: Phase 2 code is ready to activate; three commented-out "TODO PLAYER LOBBY" sections require uncommenting and integration with Steam Lobbies/Online Subsystem.

---

## Table of Contents

1. [Phase 2 Overview](#phase-2-overview)
2. [Group Ticket Architecture](#group-ticket-architecture)
3. [The Three TODO PLAYER LOBBY Sections](#the-three-todo-player-lobby-sections)
4. [Ticket Lifecycle](#ticket-lifecycle)
5. [Integration Points](#integration-points)
6. [Implementation Checklist](#implementation-checklist)

---

## Phase 2 Overview

### Requirements (from multiplayer-infrastructure.md, lines 497-524)

**Phase 2: Player Lobbies**
- Uncomment and test the `CreateMatchmakingTicketAsGroup()` function
- Wire up lobby service (likely Steam Lobbies via Online Subsystem NAME_PartySession)
- Add UI for party invite/join/ready
- Constraints:
  - **Max party size** = `max_team_size` (4 for ranked, 8 for casual)
  - **Party locking**: Once matchmaking starts, group is locked
  - **Leave constraint**: If any member leaves after `TEAM_FOUND`, entire team returns to `SEARCHING`

### Current State

The group ticket path exists in `MatchmakerComponent.cpp` but is gated behind three commented-out "TODO PLAYER LOBBY" sections:

| Section | Lines | Purpose |
|---------|-------|---------|
| TODO #1 | 410-439 | Ticket distribution pattern (map tickets to players via IP) |
| TODO #2 | 529-540 | Conditional host join logic |
| TODO #3 | 796 | Main decision point (toggle between individual vs group) |

---

## Group Ticket Architecture

### FGroupTicketRequestBody Structure

The group ticket system uses `FGroupTicketRequestBody` to send multiple players in a single matchmaking request.

**Construction Pattern** (from `CreateMatchmakingTicketAsGroup()`, lines 799-842):

```cpp
// Read players from Steam Lobby (NAME_PartySession)
FNamedOnlineSession* PartySession = GetSession("NAME_PartySession");
// Collect all registered players from the session
TArray<FPlayerInfo> GroupMembers;
for (const auto& Player : PartySession->RegisteredPlayers) {
    GroupMembers.Add(FPlayerInfo{
        PlayerId = Player.PlayerId,
        Rating = GetPlayerRating(Player.PlayerId),
        Attributes = BuildPlayerAttributes(Player)
    });
}

// Build the group request body
FGroupTicketRequestBody Request;
Request.Players = GroupMembers;
Request.GroupName = "PartyGroup_" + FString::FromInt(HostPlayerId);
Request.Attributes = GetGroupAttributes();  // game_mode, etc.

// Send via backend subsystem
DedicatedServerSubsystem->CreateGroupMatchmakingTicket(Request);
```

**Key Fields**:
- `Players`: Array of all group members (including host)
- `GroupName`: Unique identifier for the party
- `Attributes`: Contains `game_mode` (casual-8v8, ranked-4v4) for queue selection

### Ticket Distribution Mechanism

When Edgegap's group API responds, each player gets an individual ticket. The distribution pattern is shown in TODO PLAYER LOBBY #1 (lines 410-439):

```cpp
// Group API response contains:
// - tickets: Array of { ticket_id, player_ip, ... }
// - match_credentials: { game_server_id, region, ... }

// Distribution Pattern:
for (const auto& TicketInfo : GroupResponse.Tickets) {
    // Find player controller matching the ticket IP
    APlayerController* PC = FindPlayerControllerByIP(TicketInfo.player_ip);
    
    if (PC) {
        // Send ticket to this player
        PC->ClientReceivePlayerTicket(
            TicketInfo.ticket_id,
            GroupResponse.match_credentials
        );
    }
}
```

**Why IP-based matching?**
- Edgegap returns tickets with player IPs
- UE5 player controllers have accessible IP addresses via `PlayerConnection->RemoteAddr`
- Allows clean distribution without maintaining player → ticket mappings on server

---

## The Three TODO PLAYER LOBBY Sections

### TODO #1: Ticket Distribution (Lines 410-439)

**Location**: `MatchmakerComponent.cpp`, `ProcessGroupMatchmakingResponse()`

**Purpose**: Distribute individual tickets from the group API response to each player controller.

**Pattern**:
```cpp
// TODO PLAYER LOBBY (lines 410-439)
void AMatchmakerComponent::ProcessGroupMatchmakingResponse(
    const FGroupTicketResponse& Response)
{
    // Response.Tickets contains { ticket_id, player_ip, ... } for each player
    
    // Loop through players and find matching controllers by IP
    for (const auto& TicketInfo : Response.Tickets) {
        APlayerController* PC = nullptr;
        
        // Search through connected player controllers
        for (APlayerController* CurrentPC : GetWorld()->GetFirstPlayerController()->GetWorld()->GetPlayerControllerIterator()) {
            if (GetPlayerIP(CurrentPC) == TicketInfo.player_ip) {
                PC = CurrentPC;
                break;
            }
        }
        
        if (PC) {
            // Send ticket to this specific player
            PC->ClientReceivePlayerTicket_Implementation(
                TicketInfo.ticket_id,
                Response.match_credentials
            );
        }
    }
    
    // Store credentials for polling
    CurrentMatchCredentials = Response.match_credentials;
}
```

**Implementation Notes**:
- Edgegap guarantees ticket order matches request player order
- IP matching provides reliable player → ticket binding
- Each client receives only its own ticket ID (security)
- Match credentials (shared: game_server_id, region) sent to all players

**What it Replaces**: Currently, individual tickets are created per-player. This centralizes ticket creation/distribution to the group API.

---

### TODO #2: Conditional Host Join Logic (Lines 529-540)

**Location**: `MatchmakerComponent.cpp`, `PollTicketStatus()`

**Purpose**: Determine when the host can join the match after receiving `TEAM_FOUND` status.

**Pattern**:
```cpp
// TODO PLAYER LOBBY (lines 529-540)
bool AMatchmakerComponent::CanHostJoinMatch()
{
    // Check 1: Has the host travelled to the match server?
    if (!GetWorld()->GetMapName().Contains("Arcas_Gorilla_Warfare")) {
        return false;  // Not on match map yet
    }
    
    // Check 2: Have all other players joined?
    int32 PlayersJoined = 0;
    for (APlayerController* PC : GetConnectedPlayers()) {
        if (PC != HostController && IsPlayerConnected(PC)) {
            PlayersJoined++;
        }
    }
    
    // All non-host players have joined (or none expected)
    int32 ExpectedPlayers = GetGroupSize() - 1;  // Exclude host
    if (PlayersJoined >= ExpectedPlayers * 0.9f) {  // 90% threshold
        return true;
    }
    
    return false;
}
```

**Integration with PollTicketStatus()**:
```cpp
void AMatchmakerComponent::PollTicketStatus()
{
    // ... existing poll logic ...
    
    if (Response.Status == ETicketStatus::TEAM_FOUND) {
        // TODO PLAYER LOBBY: Check if host can join
        if (IsHosting && !CanHostJoinMatch()) {
            // Wait for more players
            return;
        }
        
        // Proceed with match start
        TravelToMatchServer(Response.match_credentials);
    }
}
```

**Key Constraints**:
- Host should NOT travel before other players confirm connection
- Prevents "host loads fast, everyone else gets booted" scenario
- 90% threshold allows for occasional late arrivals without blocking

---

### TODO #3: Main Decision Point (Line 796)

**Location**: `MatchmakerComponent.cpp`, `CreateMatchmakingTicket()`

**Purpose**: Toggle between individual ticket path (Phase 1) and group ticket path (Phase 2).

**Pattern**:
```cpp
void AMatchmakerComponent::CreateMatchmakingTicket()
{
    // TODO PLAYER LOBBY (line 796): Enable group tickets
    
    if (IsHostingSession("NAME_PartySession") && ShouldUseGroupTickets()) {
        // Phase 2: Create group ticket with all party members
        CreateMatchmakingTicketAsGroup();
    } else {
        // Phase 1: Create individual ticket (current behavior)
        CreateMatchmakingTicketAsIndividual();
    }
}

bool AMatchmakerComponent::ShouldUseGroupTickets() const
{
    // Return true if:
    // 1. Player is hosting a party (IsHostingSession)
    // 2. Party size > 1
    // 3. Online subsystem is available
    
    FNamedOnlineSession* PartySession = GetSession("NAME_PartySession");
    return PartySession && PartySession->RegisteredPlayers.Num() > 1;
}
```

**Current State**: The individual ticket path is active. Uncommenting this section activates the group path.

---

## Ticket Lifecycle

### Complete Flow: Individual Player → Group Matchmaking

```
┌─────────────────────────────────────────────────────────────┐
│ 1. PLAYER CREATION & PARTY FORMATION                        │
│                                                             │
│ A. Player creates/joins Steam Lobby                         │
│    - Online Subsystem (NAME_PartySession) registered        │
│    - FNamedOnlineSession::RegisteredPlayers populated       │
│                                                             │
│ B. PartySize ≤ max_team_size (4 ranked, 8 casual)          │
│    - Enforced by UI or Online Subsystem                     │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ 2. MATCHMAKING START (Host clicks "Ready")                  │
│                                                             │
│ A. Host calls CreateMatchmakingTicket()                     │
│                                                             │
│ B. TODO #3 Decision: Use group tickets?                     │
│    - YES: Call CreateMatchmakingTicketAsGroup()             │
│    - NO: Call CreateMatchmakingTicketAsIndividual() [Phase1]│
│                                                             │
│ C. CreateMatchmakingTicketAsGroup():                        │
│    - Reads RegisteredPlayers from NAME_PartySession         │
│    - Builds FGroupTicketRequestBody with all players        │
│    - Calls SendMatchmakingTicket()                          │
│    - Route: DedicatedServerSubsystem->                      │
│      CreateGroupMatchmakingTicket()                         │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ 3. TICKET DISTRIBUTION                                      │
│                                                             │
│ Edgegap Group API Response:                                │
│ {                                                           │
│   tickets: [                                                │
│     { ticket_id: "t1", player_ip: "1.1.1.1" },             │
│     { ticket_id: "t2", player_ip: "2.2.2.2" },             │
│     { ticket_id: "t3", player_ip: "3.3.3.3" }              │
│   ],                                                        │
│   match_credentials: {                                      │
│     game_server_id: "srv-123",                              │
│     region: "eu-west"                                       │
│   }                                                         │
│ }                                                           │
│                                                             │
│ ProcessGroupMatchmakingResponse():                          │
│ - TODO #1: Distribute tickets by IP matching                │
│ - Each client receives its own ticket_id                    │
│ - All clients receive same match_credentials                │
│ - Store CurrentMatchCredentials for polling                 │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ 4. MATCH ASSIGNMENT POLLING                                 │
│                                                             │
│ PollTicketStatus() (every 1.5 seconds, max 200 attempts)   │
│                                                             │
│ A. Query Edgegap: GET /ticket/{ticket_id}                  │
│                                                             │
│ B. Status responses:                                        │
│    - SEARCHING: Continue polling                           │
│    - TEAM_FOUND: Check TODO #2 (can host join?)           │
│    - MATCH_ASSIGNED: Proceed to host join check            │
│    - CANCELLED: Matchmaking failed, return to IDLE          │
│                                                             │
│ C. Host Join Decision (TODO #2):                           │
│    if (CanHostJoinMatch()) {                               │
│      TravelToMatchServer(match_credentials)                │
│    }                                                       │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ 5. MATCH SERVER CONNECTION                                  │
│                                                             │
│ A. All players travel to match server:                      │
│    ClientTravelToMatchServer(                              │
│      game_server_id,                                        │
│      region,                                                │
│      ticket_id                                              │
│    )                                                        │
│                                                             │
│ B. Server validates each ticket_id                          │
│    - Ticket in ASSIGNED state?                             │
│    - Server credentials match?                              │
│                                                             │
│ C. Player joins match with others                           │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ 6. MATCH IN PROGRESS                                        │
│                                                             │
│ A. Team members connected + playing                         │
│                                                             │
│ B. Party Lock Active:                                       │
│    - If player leaves after TEAM_FOUND → entire team        │
│      returns to SEARCHING (enforced by Online Subsystem)    │
│                                                             │
│ C. Match continues until completion or disconnection        │
└─────────────────────────────────────────────────────────────┘
```

---

## Integration Points

### 1. Online Subsystem Integration (NAME_PartySession)

**What it provides**:
- `FNamedOnlineSession* GetSession("NAME_PartySession")`
- `RegisteredPlayers`: TArray of connected party members
- Party state management (SEARCHING, TEAM_FOUND, IN_MATCH)

**How Phase 2 uses it**:
```cpp
// In CreateMatchmakingTicketAsGroup():
FNamedOnlineSession* PartySession = GetSession("NAME_PartySession");

for (const auto& RegisteredPlayer : PartySession->RegisteredPlayers) {
    // Extract player ID, rating, attributes
    GroupMembers.Add(FPlayerInfo{
        PlayerId = RegisteredPlayer.PlayerId,
        Rating = GetPlayerMMR(RegisteredPlayer.PlayerId),
        Attributes = {
            { "character_id", CurrentCharacterId },
            { "region_preference", RegionPreference }
        }
    });
}
```

**Constraints enforced by Online Subsystem**:
- Max RegisteredPlayers.Num() = max_team_size (4 ranked, 8 casual)
- Once matchmaking starts, additional players cannot join
- Leave behavior: If player leaves → entire session returns to IDLE

---

### 2. DedicatedServerBackendSubsystem Integration

**Group Ticket API Call**:
```cpp
// In DedicatedServerBackendSubsystem.cpp
void UDedicatedServerBackendSubsystem::CreateGroupMatchmakingTicket(
    const FGroupTicketRequestBody& Request,
    FOnGroupTicketResponseDelegate OnComplete)
{
    // Build HTTP POST to Edgegap
    // POST https://api.edgegap.com/v1/matchmaking/group
    // Headers: Authorization: token {EDGEGAP_API_TOKEN}
    // Body: JSON(Request)
    
    // On response: Parse JSON, call OnGroupTicketResponseDelegate
    OnComplete.ExecuteIfBound(Response);
}
```

**Response structure**:
```cpp
struct FGroupTicketResponse {
    TArray<FTicketInfo> Tickets;           // { ticket_id, player_ip }
    FMatchCredentials match_credentials;   // { game_server_id, region }
    ETicketStatus Status;                  // CREATED, ASSIGNED, etc.
};
```

---

### 3. Multicast Delegates for Event Handling

**Existing delegates** (already wired):
- `FOnTicketIdVerified`: When ticket_id verified by server
- `FOnTicketFailure`: When Edgegap rejects ticket
- `FOnMatchmakerCredentialsReceived`: When match_credentials available

**New delegates needed for Phase 2**:
```cpp
// Add to FMatchmakerComponent in header:

// When group ticket response received
DECLARE_MULTICAST_DELEGATE_OneParam(FOnGroupTicketResponse, 
    const FGroupTicketResponse&, Response);
FOnGroupTicketResponse OnGroupTicketResponse;

// When player successfully receives distributed ticket
DECLARE_MULTICAST_DELEGATE_TwoParams(FOnPlayerTicketDistributed,
    const FString&, TicketId,
    APlayerController*, PlayerController);
FOnPlayerTicketDistributed OnPlayerTicketDistributed;

// When host join condition satisfied
DECLARE_MULTICAST_DELEGATE(FOnHostCanJoinMatch);
FOnHostCanJoinMatch OnHostCanJoinMatch;
```

---

## Implementation Checklist

### Phase 2 Activation Checklist

- [ ] **Uncomment TODO PLAYER LOBBY #1 (lines 410-439)**
  - [ ] Review ticket distribution pattern
  - [ ] Verify IP-matching logic works with current player controller setup
  - [ ] Test with 2+ players to confirm each gets correct ticket
  - [ ] Add logging: "Distributed ticket_id={ticket} to player_ip={ip}"

- [ ] **Uncomment TODO PLAYER LOBBY #2 (lines 529-540)**
  - [ ] Review CanHostJoinMatch() logic
  - [ ] Adjust 90% threshold if needed based on testing
  - [ ] Add logging: "Checking if host can join... expected={ExpectedPlayers}, connected={PlayersJoined}"
  - [ ] Integrate with PollTicketStatus() - add conditional check before TravelToMatchServer

- [ ] **Uncomment TODO PLAYER LOBBY #3 (line 796)**
  - [ ] Add ShouldUseGroupTickets() helper function
  - [ ] Logic: IsHosting("NAME_PartySession") && PartySize > 1
  - [ ] Route traffic to CreateMatchmakingTicketAsGroup() when true
  - [ ] Add logging: "Using group tickets={UseGroupTickets}"

- [ ] **Wire up NAME_PartySession**
  - [ ] Verify Online Subsystem exposes NAME_PartySession
  - [ ] Test GetSession("NAME_PartySession") returns valid session
  - [ ] Verify RegisteredPlayers populates when Steam Lobby created
  - [ ] Add logging: "PartySession RegisteredPlayers={count}"

- [ ] **Test Group Ticket Lifecycle**
  - [ ] Create party with 2 players (solo host + 1 guest)
  - [ ] Host starts matchmaking
  - [ ] Verify TODO #1 distribution: each player receives own ticket
  - [ ] Verify polling proceeds correctly
  - [ ] Verify TODO #2 host join condition triggers
  - [ ] Verify host travels to server with all tickets
  - [ ] Verify match starts with full team

- [ ] **Test Party Constraints**
  - [ ] Verify max party size enforced (4 ranked, 8 casual)
  - [ ] Test adding player while in SEARCHING state (should fail)
  - [ ] Test player leaving after TEAM_FOUND (entire team returns to SEARCHING)
  - [ ] Add logging for constraint violations

- [ ] **UI Integration**
  - [ ] Add party creation button in main menu
  - [ ] Add party invite/join flow (likely via Steam Lobbies)
  - [ ] Add "Ready" button (host only) to start matchmaking
  - [ ] Show party member list with readiness status
  - [ ] Show matchmaking progress: SEARCHING → TEAM_FOUND → MATCH_ASSIGNED

- [ ] **Performance & Reliability**
  - [ ] Profile IP-matching during ticket distribution (1000+ players?)
  - [ ] Monitor ticket delivery latency
  - [ ] Test network disconnect during polling (player rejoining?)
  - [ ] Test Edgegap API timeout handling

- [ ] **Documentation**
  - [ ] Add code comments explaining group ticket flow
  - [ ] Document NAME_PartySession dependency
  - [ ] Document max_team_size constraint enforcement
  - [ ] Document party locking behavior

---

## Critical Integration Details

### IP Matching Reliability

**Why IP-based distribution works**:
1. Edgegap returns `player_ip` for each ticket
2. UE5 player controllers have accessible remote address via `PlayerConnection->RemoteAddr`
3. No need for client → server ticket mapping

**Edge cases to handle**:
- NAT/proxies: Multiple players from same IP (rare in matchmaking, but possible)
- Local network testing: All players have same 127.0.0.1 (mock test only)
- IPv6 vs IPv4: Ensure consistent IP format

**Recommended implementation**:
```cpp
FString GetPlayerIP(APlayerController* PC) {
    if (!PC || !PC->PlayerConnection) return "";
    
    FString RemoteIP = PC->PlayerConnection->RemoteAddr->ToString(false);
    // Removes :port, returns just IP
    return RemoteIP;
}
```

### Party Locking Constraint

This is enforced by the Online Subsystem, NOT the matchmaking component:

**When lockout occurs**:
- After receiving `TEAM_FOUND` status from Edgegap
- Player leaves → FNamedOnlineSession fires UnregisterPlayer event
- Session manager broadcasts to all members: "Return to SEARCHING"

**Phase 2 must respect**:
- Cannot re-enter matchmaking while other players still have tickets
- Must handle disconnects gracefully (player reconnect vs leave)

---

## Summary

Phase 2 player lobby functionality is **ready to activate**. The three commented-out "TODO PLAYER LOBBY" sections provide:

1. **Ticket Distribution** (TODO #1): Maps Edgegap response tickets to individual players via IP
2. **Host Join Logic** (TODO #2): Ensures host waits for other players before joining match
3. **Decision Point** (TODO #3): Activates group ticket path when hosting a party

**Prerequisites for activation**:
- Steam Lobbies wired to NAME_PartySession (Online Subsystem)
- Party UI for invite/join/ready
- Max party size enforcement (4 ranked, 8 casual)

**Timeline**: All code patterns are documented and ready; activation is primarily a matter of uncommenting, testing constraint enforcement, and wiring UI.


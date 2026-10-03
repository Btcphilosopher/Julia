module AppleAIGuard

using Dates
using UUIDs

# ============================================================
# Apple AI Guard
# Policy engine for protecting personal/private data
#
# IMPORTANT:
# This module is NOT itself an iOS kernel firewall.
# It is intended to provide policy decisions to an iOS
# application that performs the actual Apple API enforcement.
# ============================================================

export AgentIdentity,
       ResourceRequest,
       SecurityPolicy,
       SecurityDecision,
       evaluate_request,
       audit_event,
       block_agent!,
       unblock_agent!,
       add_private_path!,
       remove_private_path!,
       set_global_lockdown!,
       security_status

# ------------------------------------------------------------
# ENUMERATIONS
# ------------------------------------------------------------

@enum Decision begin
    ALLOW
    DENY
    REQUIRE_USER_APPROVAL
end

@enum ResourceClass begin
    PUBLIC_DATA
    USER_DATA
    PRIVATE_DATA
    CREDENTIAL
    SYSTEM_DATA
    HEALTH_DATA
    FINANCIAL_DATA
    LOCATION_DATA
    COMMUNICATION_DATA
end

# ------------------------------------------------------------
# AGENT IDENTITY
# ------------------------------------------------------------

mutable struct AgentIdentity
    id::UUID
    name::String
    bundle_id::String
    signed::Bool
    developer_team::String
    requested_entitlements::Set{String}
    declared_purpose::String
    trust_score::Float64
    blocked::Bool
end

function AgentIdentity(
    name::String,
    bundle_id::String;
    signed=true,
    developer_team="",
    entitlements=String[],
    purpose=""
)

    AgentIdentity(
        uuid4(),
        name,
        bundle_id,
        signed,
        developer_team,
        Set(entitlements),
        purpose,
        0.0,
        false
    )
end

# ------------------------------------------------------------
# RESOURCE REQUEST
# ------------------------------------------------------------

struct ResourceRequest
    agent::AgentIdentity
    resource::String
    resource_class::ResourceClass
    operation::Symbol

    requested_at::DateTime

    recursive::Bool
    estimated_bytes::Int64

    requires_full_disk_access::Bool
    contains_personal_data::Bool
    contains_credentials::Bool
end

function ResourceRequest(
    agent,
    resource,
    resource_class,
    operation;
    recursive=false,
    estimated_bytes=0,
    requires_full_disk_access=false,
    contains_personal_data=false,
    contains_credentials=false
)

    ResourceRequest(
        agent,
        resource,
        resource_class,
        operation,
        now(),
        recursive,
        estimated_bytes,
        requires_full_disk_access,
        contains_personal_data,
        contains_credentials
    )
end

# ------------------------------------------------------------
# POLICY
# ------------------------------------------------------------

mutable struct SecurityPolicy

    # Master switch
    lockdown::Bool

    # Agents explicitly denied
    blocked_agents::Set{UUID}

    # Paths which are always private
    private_paths::Set{String}

    # Credential paths
    credential_paths::Set{String}

    # Maximum bytes an agent can request
    max_request_bytes::Int64

    # Recursive requests require additional approval
    prohibit_recursive_requests::Bool

    # Credentials can never be exposed
    protect_credentials::Bool

    # Personal data requires approval
    protect_personal_data::Bool

    # Full disk access is considered extremely privileged
    prohibit_full_disk_ai_access::Bool

    # Maximum number of requests per minute
    max_requests_per_minute::Int

    # Request history
    request_history::Dict{UUID,Vector{DateTime}}

    # Audit trail
    audit_log::Vector{Dict{Symbol,Any}}
end

function SecurityPolicy()

    SecurityPolicy(
        false,
        Set{UUID}(),
        Set{String}(),
        Set{String}(),
        10 * 1024 * 1024,
        true,
        true,
        true,
        true,
        60,
        Dict{UUID,Vector{DateTime}}(),
        Dict{Symbol,Any}[]
    )

end

# ------------------------------------------------------------
# SECURITY DECISION
# ------------------------------------------------------------

struct SecurityDecision

    decision::Decision

    score::Float64

    reasons::Vector{String}

    timestamp::DateTime

    agent_id::UUID

    resource::String
end

# ------------------------------------------------------------
# PATH NORMALISATION
# ------------------------------------------------------------

function normalize_path(path::String)

    p = replace(path, "\\" => "/")

    # Collapse repeated slashes
    p = replace(p, r"/+" => "/")

    return lowercase(p)
end

function path_matches(path::String, protected::Set{String})

    p = normalize_path(path)

    for candidate in protected

        c = normalize_path(candidate)

        if startswith(p, c)
            return true
        end
    end

    return false
end

# ------------------------------------------------------------
# PRIVATE RESOURCE DETECTION
# ------------------------------------------------------------

function classify_resource(req::ResourceRequest)

    p = normalize_path(req.resource)

    if req.contains_credentials
        return CREDENTIAL
    end

    if occursin("keychain", p)
        return CREDENTIAL
    end

    if occursin("password", p)
        return CREDENTIAL
    end

    if occursin("token", p)
        return CREDENTIAL
    end

    if occursin("health", p)
        return HEALTH_DATA
    end

    if occursin("location", p)
        return LOCATION_DATA
    end

    if occursin("financial", p)
        return FINANCIAL_DATA
    end

    if req.contains_personal_data
        return PRIVATE_DATA
    end

    return req.resource_class
end

# ------------------------------------------------------------
# REQUEST RATE LIMITING
# ------------------------------------------------------------

function check_rate_limit!(
    policy::SecurityPolicy,
    agent::AgentIdentity
)

    t = now()

    history = get!(
        policy.request_history,
        agent.id,
        DateTime[]
    )

    cutoff = t - Minute(1)

    filter!(x -> x >= cutoff, history)

    push!(history, t)

    return length(history) <= policy.max_requests_per_minute
end

# ------------------------------------------------------------
# TRUST SCORING
# ------------------------------------------------------------

function calculate_risk(
    policy::SecurityPolicy,
    req::ResourceRequest
)

    risk = 0.0
    reasons = String[]

    agent = req.agent

    # Unsigned agent
    if !agent.signed
        risk += 0.30
        push!(reasons, "Unsigned or unverified agent")
    end

    # Existing block
    if agent.blocked ||
       agent.id in policy.blocked_agents

        risk += 1.0
        push!(reasons, "Agent is explicitly blocked")
    end

    # Full disk access
    if req.requires_full_disk_access

        risk += 0.80

        push!(
            reasons,
            "Request requires full-disk-level access"
        )
    end

    # Recursive filesystem traversal
    if req.recursive

        risk += 0.30

        push!(
            reasons,
            "Recursive filesystem traversal requested"
        )
    end

    # Credentials
    if req.contains_credentials

        risk += 1.0

        push!(
            reasons,
            "Credential material requested"
        )
    end

    # Personal information
    if req.contains_personal_data

        risk += 0.45

        push!(
            reasons,
            "Personal data requested"
        )
    end

    # Large request
    if req.estimated_bytes > policy.max_request_bytes

        risk += 0.30

        push!(
            reasons,
            "Requested data volume exceeds policy limit"
        )
    end

    # Protected paths
    if path_matches(
        req.resource,
        policy.private_paths
    )

        risk += 0.80

        push!(
            reasons,
            "Protected private path"
        )
    end

    if path_matches(
        req.resource,
        policy.credential_paths
    )

        risk += 1.0

        push!(
            reasons,
            "Protected credential path"
        )
    end

    # Sensitive classes
    cls = classify_resource(req)

    if cls == HEALTH_DATA

        risk += 0.80
        push!(reasons, "Health data")

    elseif cls == FINANCIAL_DATA

        risk += 0.80
        push!(reasons, "Financial data")

    elseif cls == LOCATION_DATA

        risk += 0.60
        push!(reasons, "Location data")

    elseif cls == COMMUNICATION_DATA

        risk += 0.60
        push!(reasons, "Communication data")
    end

    return min(risk, 1.0), reasons
end

# ------------------------------------------------------------
# POLICY ENGINE
# ------------------------------------------------------------

function evaluate_request(
    policy::SecurityPolicy,
    req::ResourceRequest
)

    agent = req.agent

    # --------------------------------------------------------
    # Absolute blocks
    # --------------------------------------------------------

    if policy.lockdown

        decision = SecurityDecision(
            DENY,
            1.0,
            ["Global security lockdown enabled"],
            now(),
            agent.id,
            req.resource
        )

        audit_event(policy, req, decision)

        return decision
    end

    if agent.blocked ||
       agent.id in policy.blocked_agents

        decision = SecurityDecision(
            DENY,
            1.0,
            ["Agent is blocked"],
            now(),
            agent.id,
            req.resource
        )

        audit_event(policy, req, decision)

        return decision
    end

    # --------------------------------------------------------
    # Rate limiting
    # --------------------------------------------------------

    if !check_rate_limit!(policy, agent)

        decision = SecurityDecision(
            DENY,
            0.95,
            ["Agent exceeded request-rate limit"],
            now(),
            agent.id,
            req.resource
        )

        audit_event(policy, req, decision)

        return decision
    end

    # --------------------------------------------------------
    # Calculate risk
    # --------------------------------------------------------

    risk, reasons =
        calculate_risk(policy, req)

    # --------------------------------------------------------
    # Credential protection
    # --------------------------------------------------------

    if policy.protect_credentials &&
       classify_resource(req) == CREDENTIAL

        decision = SecurityDecision(
            DENY,
            1.0,
            [reasons; "Credentials cannot be exposed"],
            now(),
            agent.id,
            req.resource
        )

        audit_event(policy, req, decision)

        return decision
    end

    # --------------------------------------------------------
    # Full disk protection
    # --------------------------------------------------------

    if policy.prohibit_full_disk_ai_access &&
       req.requires_full_disk_access

        decision = SecurityDecision(
            DENY,
            max(risk, 0.95),
            [reasons; "AI agents cannot receive full-disk access"],
            now(),
            agent.id,
            req.resource
        )

        audit_event(policy, req, decision)

        return decision
    end

    # --------------------------------------------------------
    # Recursive access
    # --------------------------------------------------------

    if policy.prohibit_recursive_requests &&
       req.recursive

        decision = SecurityDecision(
            REQUIRE_USER_APPROVAL,
            max(risk, 0.70),
            [reasons; "Recursive access requires explicit approval"],
            now(),
            agent.id,
            req.resource
        )

        audit_event(policy, req, decision)

        return decision
    end

    # --------------------------------------------------------
    # Personal data
    # --------------------------------------------------------

    if policy.protect_personal_data &&
       req.contains_personal_data

        decision = SecurityDecision(
            REQUIRE_USER_APPROVAL,
            max(risk, 0.70),
            [reasons; "Personal data requires user approval"],
            now(),
            agent.id,
            req.resource
        )

        audit_event(policy, req, decision)

        return decision
    end

    # --------------------------------------------------------
    # Risk thresholds
    # --------------------------------------------------------

    if risk >= 0.85

        decision = SecurityDecision(
            DENY,
            risk,
            reasons,
            now(),
            agent.id,
            req.resource
        )

    elseif risk >= 0.50

        decision = SecurityDecision(
            REQUIRE_USER_APPROVAL,
            risk,
            reasons,
            now(),
            agent.id,
            req.resource
        )

    else

        decision = SecurityDecision(
            ALLOW,
            risk,
            reasons,
            now(),
            agent.id,
            req.resource
        )
    end

    audit_event(policy, req, decision)

    return decision
end

# ------------------------------------------------------------
# AUDITING
# ------------------------------------------------------------

function audit_event(
    policy::SecurityPolicy,
    req::ResourceRequest,
    decision::SecurityDecision
)

    event = Dict{Symbol,Any}(
        :timestamp => decision.timestamp,
        :agent_id => string(decision.agent_id),
        :agent_name => req.agent.name,
        :bundle_id => req.agent.bundle_id,
        :resource => req.resource,
        :operation => string(req.operation),
        :decision => string(decision.decision),
        :risk => decision.score,
        :reasons => decision.reasons
    )

    push!(policy.audit_log, event)

    return event
end

# ------------------------------------------------------------
# AGENT MANAGEMENT
# ------------------------------------------------------------

function block_agent!(
    policy::SecurityPolicy,
    agent::AgentIdentity
)

    agent.blocked = true
    push!(policy.blocked_agents, agent.id)

    return true
end

function unblock_agent!(
    policy::SecurityPolicy,
    agent::AgentIdentity
)

    agent.blocked = false
    delete!(policy.blocked_agents, agent.id)

    return true
end

# ------------------------------------------------------------
# PRIVATE PATH MANAGEMENT
# ------------------------------------------------------------

function add_private_path!(
    policy::SecurityPolicy,
    path::String
)

    push!(policy.private_paths, path)

    return true
end

function remove_private_path!(
    policy::SecurityPolicy,
    path::String
)

    delete!(policy.private_paths, path)

    return true
end

# ------------------------------------------------------------
# LOCKDOWN
# ------------------------------------------------------------

function set_global_lockdown!(
    policy::SecurityPolicy,
    enabled::Bool
)

    policy.lockdown = enabled

    return policy.lockdown
end

# ------------------------------------------------------------
# SECURITY STATUS
# ------------------------------------------------------------

function security_status(policy::SecurityPolicy)

    return Dict(
        :lockdown => policy.lockdown,
        :blocked_agents => length(policy.blocked_agents),
        :private_paths => length(policy.private_paths),
        :credential_paths => length(policy.credential_paths),
        :audit_events => length(policy.audit_log),
        :max_request_bytes => policy.max_request_bytes
    )

end

end # module


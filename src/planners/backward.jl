export BackwardPlanner, BackwardGreedyPlanner, BackwardAStarPlanner

"Heuristic-guided best-first backward search."
@kwdef mutable struct BackwardPlanner <: Planner
    heuristic::Heuristic = GoalCountHeuristic(:backward)
    g_mult::Float64 = 1.0 # Path cost multiplier
    h_mult::Float64 = 1.0 # Heuristic multiplier
    max_nodes::Int = typemax(Int)
    save_search::Bool = false # Flag to save search info
end

"Backward greedy search, with cycle checking."
BackwardGreedyPlanner(heuristic::Heuristic; kwargs...) =
    BackwardPlanner(;heuristic=heuristic, g_mult=0, kwargs...)

"Backward A* search."
BackwardAStarPlanner(heuristic::Heuristic; kwargs...) =
    BackwardPlanner(;heuristic=heuristic, kwargs...)

function solve(planner::BackwardPlanner,
               domain::Domain, state::State, goal_spec::GoalSpec)
    @unpack goals = goal_spec
    @unpack h_mult, heuristic, save_search = planner
    # Construct references to start and goal states
    start = state
    state = State(goal_spec.goals, PDDL.get_types(start))
    # Initialize search tree and priority queue
    node_id = hash(state)
    search_tree = SearchTree(node_id => SearchNode(node_id, state, 0))
    est_cost = h_mult * heuristic(domain, state, goal_spec)
    queue = PriorityQueue{UInt,Float64}(node_id => est_cost)
    # Run the search
    status, node_id =
        search!(planner, domain, goal_spec, start, search_tree, queue)
    # Reconstruct plan and return solution
    if status != :failure
        plan, traj = reconstruct(node_id, search_tree)
        reverse!(plan); reverse!(traj)
        if save_search
            return SearchSolution(status, plan, traj, search_tree, queue)
        else
            return SearchSolution(status, plan, traj)
        end
    elseif save_search
        return SearchSolution(status, [], [], search_tree, queue)
    else
        return NullSolution()
    end
end

function search!(planner::BackwardPlanner,
                 domain::Domain, goal_spec::GoalSpec, start::State,
                 search_tree::SearchTree, queue::PriorityQueue)
    @unpack constraints = goal_spec
    constraints = isempty(constraints) ? nothing : precond_diff(constraints)
    count = 1
    while length(queue) > 0
        # Get state with lowest estimated cost to start state
        node_id = dequeue!(queue)
        node = search_tree[node_id]
        # Return status and current state if search terminates
        if issubset(node.state, start)
            return :success, node_id # Start state reached
        elseif count >= planner.max_nodes
            return :max_nodes, node_id # Node budget reached
        end
        count += 1
        # Expand current node
        expand!(planner, node, search_tree, queue,
                domain, goal_spec, constraints)
    end
    return :failure, nothing
end

function expand!(planner::BackwardPlanner, node::SearchNode,
                 search_tree::SearchTree, queue::PriorityQueue,
                 domain::Domain, goal_spec::GoalSpec, constraints)
    @unpack g_mult, h_mult, heuristic = planner
    @unpack metric = goal_spec
    state = node.state
    # Iterate over relevant actions
    actions = relevant(state, domain)
    for act in actions
        # Regress (reverse-execute) the action
        next_state = regress(act, state, domain; check=false)
        # Add constraints to regression state
        if (constraints !== nothing) update!(next_state, constraints) end
        next_id = hash(next_state)
        # Compute path cost
        act_cost = metric == nothing ? 1 :
            state[domain, metric] - next_state[domain, metric]
        path_cost = node.path_cost + act_cost
        # Update path costs if new path is shorter
        next_node = get!(search_tree, next_id,
                         SearchNode(next_id, next_state, Inf))
        cost_diff = next_node.path_cost - path_cost
        if cost_diff > 0
            next_node.parent_id = node.id
            next_node.parent_action = act
            next_node.path_cost = path_cost
            # Update estimated cost from next state to start
            if !(next_id in keys(queue))
                g_val = g_mult * path_cost
                h_val = h_mult * heuristic(domain, next_state, goal_spec)
                enqueue!(queue, next_id, g_val + h_val)
            else
                queue[next_id] -= cost_diff
            end
        end
    end
end

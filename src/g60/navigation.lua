-- ★★★ 2026-10-05：逐字移植上游 1.1.0 的 `Navigation`（2026-10-05，用户拍板"泰坦方面全部改成上游"）★★★
--   = **泰坦专用**的可见性图导航（"Bounded visibility-graph navigation in a body-relative
--     reference obstacle model"）。 `M.reference` 是泰坦机身网格盒（bind Z=8.847）。
--   ⚠ 上游原文：`_refs/upstream-g60st-1.1.0-body.lua` 2577-2753，逐字未改。
--   ⚠ 它**不做**引擎碰撞查询/地形导航，也不宣称最优；只在参考模型里找一条不穿身的折线。
--   调用方：`adaptive.lua` 的 `kind=="titan"` 分支。
-- Bounded visibility-graph navigation in a body-relative reference obstacle model.
-- Not engine collision queries, terrain navigation or a global optimality proof.
local M={radius=60,margin=0.12}
local sqrt,abs,min,max=math.sqrt,math.abs,math.min,math.max
local function clamp(x,a,b)return max(a,min(b,x))end
local function copy(a)return {a[1],a[2],a[3]}end
local function dist(a,b)return sqrt((a[1]-b[1])^2+(a[2]-b[2])^2+(a[3]-b[3])^2)end
local function dot(a,b)return a[1]*b[1]+a[2]*b[2]+a[3]*b[3]end
local function unit(a)local n=sqrt(dot(a,a));assert(n>.5 and n<2,'navigation basis');return {a[1]/n,a[2]/n,a[3]/n}end
local function cross(a,b)return {a[2]*b[3]-a[3]*b[2],a[3]*b[1]-a[1]*b[3],a[1]*b[2]-a[2]*b[1]}end
-- Indexed intact mesh bounds in the local game asset, metres; body bind Z=8.847.
-- Torso/head/tail and the four outer legs. Inner limbs are included separately.
-- The proxies follow the observed body frame; individual animated legs are NOT read.
M.reference={
 {name='torso',lo={-2.05,-3.10,5.92},hi={2.05,2.25,10.17}},
 {name='carapace',lo={-2.67,-2.39,7.30},hi={2.67,1.96,10.52}},
 {name='head',lo={-1.15,1.20,6.95},hi={1.15,3.44,10.05}},
 {name='tail',lo={-1.83,-8.29,4.42},hi={1.83,-1.00,8.54}},
 {name='front_left',lo={-6.58,2.11,-1.57},hi={-2.54,6.32,10.56}},
 {name='front_right',lo={2.54,2.11,-1.57},hi={6.58,6.32,10.56}},
 {name='rear_left',lo={-6.28,-7.40,-1.50},hi={-2.39,-2.87,10.52}},
 {name='rear_right',lo={2.39,-7.40,-1.50},hi={6.28,-2.87,10.52}},
 {name='inner_front',lo={-3.96,0.02,3.96},hi={3.98,3.52,8.86}},
 {name='inner_rear',lo={-3.95,-4.34,4.02},hi={3.95,-0.64,9.02}}
}
-- Inner-leg boxes would fill the belly gap if merged across left/right.
-- Split at the actual inner limb edge, leaving the central passage open.
local boxes={}
for _,b in ipairs(M.reference)do
 if b.name=='inner_front' or b.name=='inner_rear' then
  for _,sign in ipairs({-1,1})do
   local lo,hi=copy(b.lo),copy(b.hi)
   if sign<0 then hi[1]=-0.27 else lo[1]=0.27 end
   boxes[#boxes+1]={name=b.name..sign,lo=lo,hi=hi}
  end
 else boxes[#boxes+1]=b end
end
M.boxes=boxes
function M.frame(t)
 local right=unit(t.right);local forward=unit(t.forward or {-right[2],right[1],0})
 assert(abs(dot(right,forward))<.05,'navigation orthogonality')
 local up=unit(cross(right,forward));forward=unit(cross(up,right))
 return {origin=t.body_center,right=right,forward=forward,up=up}
end
function M.local_point(f,p)
 local d={p[1]-f.origin[1],p[2]-f.origin[2],p[3]-f.origin[3]}
 return {dot(d,f.right),dot(d,f.forward)-.208,dot(d,f.up)+8.847}
end
function M.world_point(f,p)
 local out={};for k=1,3 do out[k]=f.origin[k]+p[1]*f.right[k]+(p[2]+.208)*f.forward[k]+(p[3]-8.847)*f.up[k]end
 return out
end
local function inside(p,b)
 return p[1]>b.lo[1]+1e-7 and p[1]<b.hi[1]-1e-7 and p[2]>b.lo[2]+1e-7 and p[2]<b.hi[2]-1e-7
  and p[3]>b.lo[3]+1e-7 and p[3]<b.hi[3]-1e-7
end
function M.blocked(a,b)
 for _,box in ipairs(boxes)do
  local enter,leave=0,1
  for k=1,3 do
   local d=b[k]-a[k];local lo,hi=box.lo[k]+1e-6,box.hi[k]-1e-6
   if abs(d)<1e-10 then if a[k]<=lo or a[k]>=hi then leave=-1;break end
   else
    local x,y=(lo-a[k])/d,(hi-a[k])/d;if x>y then x,y=y,x end
    enter=max(enter,x);leave=min(leave,y);if enter>=leave then break end
   end
  end
  if enter<leave and leave>0 and enter<1 then return true,box.name end
 end
 return false
end
local function occupied(p)for _,b in ipairs(boxes)do if inside(p,b)then return true end end;return false end
local function project(p,c,r)
 local n=r.normal;local d={p[1]-c[1],p[2]-c[2],p[3]-c[3]};local along=dot(d,n)
 local v={d[1]-along*n[1],d[2]-along*n[2],d[3]-along*n[3]};local rad=sqrt(dot(v,v))
 local scale=rad>r.radius-.08 and (r.radius-.08)/rad or 1;local out={}
 for k=1,3 do out[k]=c[k]+v[k]*scale+n[k]*clamp(along,r.depth*.1,r.depth*.9)end
 if out[3]<r.min_z+.015 then for k=1,3 do out[k]=c[k]+n[k]*r.depth*.1 end end
 return out
end
M.project=project
local function usable(p,f,floor)return M.world_point(f,p)[3]>=floor-.001 and not occupied(p)end
local function graph(start,goal,f,floor)
 local nodes={};local seen={}
 local function add(p)
  if not usable(p,f,floor)then return end
  local key=string.format('%.3f/%.3f/%.3f',p[1],p[2],p[3]);if seen[key]then return end
  seen[key]=true;nodes[#nodes+1]=p
 end
 -- Corners plus edge points at the start/goal's intermediate coordinate.
 -- These allow over-body starts to slip around a nearby edge, not a 12 m ring.
 for _,b in ipairs(boxes)do
  local lo,hi={},{};for k=1,3 do lo[k]=b.lo[k]-.25;hi[k]=b.hi[k]+.25 end
  for x=0,1 do for y=0,1 do for z=0,1 do add({x==0 and lo[1]or hi[1],y==0 and lo[2]or hi[2],z==0 and lo[3]or hi[3]})end end end
  for axis=1,3 do
   local a=axis%3+1;local baxis=a%3+1
   for i=0,1 do for j=0,1 do
    local p={};p[axis]=clamp((start[axis]+goal[axis])*.5,lo[axis],hi[axis]);p[a]=i==0 and lo[a]or hi[a];p[baxis]=j==0 and lo[baxis]or hi[baxis];add(p)
   end end
  end
 end
 assert(#nodes<=240,'navigation graph bound');return nodes
end
local function escape(start,f,floor)
 local best,bestd
 -- Exit the union of overlapping proxy boxes by the nearest axis-aligned ray.
 for k=1,3 do for _,sign in ipairs({-1,1})do
  local p=copy(start)
  for _=1,#boxes+1 do
   local moved=false
   for _,b in ipairs(boxes)do if inside(p,b)then p[k]=(sign<0 and b.lo[k]-.35 or b.hi[k]+.35);moved=true end end
   if not moved then break end
  end
  if usable(p,f,floor)then local d=dist(start,p);if not bestd or d<bestd then best,bestd=p,d end end
 end end
 return best
end
function M.plan(own,t,c,r,previous,now)
 local f=M.frame(t);local start=M.local_point(f,own);local world_goal=project(own,c,r);local goal=M.local_point(f,world_goal)
 if usable(goal,f,r.min_z)and not M.blocked(start,goal)then
  return {point=world_goal,terminal=true,mode='direct',state={path={goal},at=now,center=copy(c),normal=copy(r.normal)},length=dist(own,world_goal),nodes=0}
 end
 if occupied(start)then
  local p=escape(start,f,r.min_z);if not p then return nil,'navigation proxy escape unavailable' end
  return {point=M.world_point(f,p),terminal=false,mode='escape',state={path={p},at=now,center=copy(c),normal=copy(r.normal)},length=dist(start,p),nodes=0}
 end
 -- Reuse the remaining corridor for a bounded interval, but test the direct
 -- shortcut above on EVERY update, and validate each reused next segment.
 if previous and now-previous.at>=0 and now-previous.at<.35 and dist(previous.center,c)<.5 and dot(previous.normal,r.normal)>.995 then
  local path={};for _,p in ipairs(previous.path)do path[#path+1]=copy(p)end
  while #path>0 and dist(start,path[1])<.18 do table.remove(path,1)end
  if #path>0 and usable(path[1],f,r.min_z)and not M.blocked(start,path[1])then
   return {point=M.world_point(f,path[1]),terminal=false,mode='detour',state={path=path,at=previous.at,center=copy(c),normal=copy(r.normal)},nodes=0}
  end
 end
 local nodes=graph(start,goal,f,r.min_z);table.insert(nodes,1,start)
 local count=#nodes;local costs={[1]=0};local parent,visited={},{};local best,bestgoal,bestcost
 local candidates={world_goal}
 -- Alternative points around the CURRENT tilted detonation volume, all inset.
 local basis=unit(abs(r.normal[1])<.8 and cross(r.normal,{1,0,0})or cross(r.normal,{0,1,0}));local second=cross(r.normal,basis)
 for i=0,7 do for _,depth in ipairs({.1,.5,.9})do
  local a=i*math.pi/4;local p={}
  for k=1,3 do p[k]=c[k]+r.normal[k]*r.depth*depth+(basis[k]*math.cos(a)+second[k]*math.sin(a))*(r.radius-.08)end
  if p[3]>=r.min_z+.01 then candidates[#candidates+1]=p end
 end end
 local goals={};for _,p in ipairs(candidates)do local q=M.local_point(f,p);if usable(q,f,r.min_z)then goals[#goals+1]=q end end
 for _=1,count do
  local u,score
  for i=1,count do if not visited[i]and costs[i]and(not score or costs[i]<score)then u,score=i,costs[i]end end
  if not u or bestcost and score>=bestcost then break end
  visited[u]=true
  local projected=M.local_point(f,project(M.world_point(f,nodes[u]),c,r))
  local function finish(g)
   local cost=score+dist(nodes[u],g)
   if(not bestcost or cost<bestcost)and usable(g,f,r.min_z)and not M.blocked(nodes[u],g)then best,bestgoal,bestcost=u,g,cost end
  end
  finish(projected);for _,g in ipairs(goals)do finish(g)end
  for v=2,count do if not visited[v]then
   local cost=score+dist(nodes[u],nodes[v])
   if(not costs[v]or cost<costs[v])and(not bestcost or cost<bestcost)and not M.blocked(nodes[u],nodes[v])then costs[v]=cost;parent[v]=u end
  end end
 end
 if not best then return nil,'navigation has no clear route in reference model' end
 local path={bestgoal};local u=best
 while u and u~=1 do table.insert(path,1,nodes[u]);u=parent[u]end
 -- String pulling removes redundant vertices; it never crosses a proxy.
 local from=start;local i=1
 while i<=#path do
  local far=i;for j=i+1,#path do if not M.blocked(from,path[j])then far=j end end
  for _=i,far-1 do table.remove(path,i)end
  from=path[i];i=i+1
 end
 local length=0;from=start;for _,p in ipairs(path)do length=length+dist(from,p);from=p end
 return {point=M.world_point(f,path[1]),terminal=#path==1,mode=#path==1 and'direct'or'detour',state={path=path,at=now,center=copy(c),normal=copy(r.normal)},length=length,nodes=count}
end
return M

---
layout: post
title: "Building shared memory for a team of agents"
description: "And lessons from running them for 6 months in 6 projects"
date: 2026-11-10
image: /assets/shared-memory/card.png
tags: [agents, memory, jean]
---

Have you ever felt like you need to reintroduce a fresh Claude Code to the same details about your project? Copy a context summary from one session into another? Wished you could just tell Claude Code to dispatch a separate task to another session, and have that session immediately pick up both the task context and a collective memory of all previous sessions in that project?

I have, and this was my motivation behind building [Jean](https://github.com/leonidb/jean), an unopinionated framework for managing a group of agents that work in coordination on tasks and accumulate collective knowledge of the project, the way you like to work, and how to function as a team of agents, refining it as they go.

This post focuses on my experience and lessons I've learned from building Jean's shared memory. I've been running 6 projects over about 6 months on this infra, from a personal assistant to work projects, and it's interesting to see how a general infra for shared memory gets a personality and evolves in real life in different projects.

## How I built it

A shared memory for several sessions was on my mind at the very beginning, when I first set out to build Jean.

I wanted a project-level memory that is both shared between all the agents that work on a project, so I don't need to retell the same thing to a new agent, and focused on the project, not general to everything I do in Claude Code.

My initial inspiration came from Andrej Karpathy's [idea of a fully LLM-managed wiki](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f), which got quite popular. At the time quite a few people noted that self-organized Markdown really does work and maybe that's all you need. I took that idea but adapted it in a more structural, frameworky way, because the original was about managing documents.

<figure>
  <img src="{{ '/assets/shared-memory/loop.svg' | relative_url }}" width="760" alt="Agents memorize and their task threads go into the event log; the nightly librarian (draft, review, commit) turns new events into the wiki; one-stop search reads the wiki pages and what is not consolidated yet, and agents read from it; the sensei runs a weekly staleness sweep into the event log.">
</figure>

Jean is built on an event log: what agents memorize and their task threads are appended to it and never edited. No agent edits the wiki directly: it changes only through the log. Once a day a headless agent, the librarian, consolidates the new events into a Markdown wiki. One search covers the wiki and what isn't consolidated yet. Once a week the sensei, the orchestrating agent, sweeps the wiki for stale facts and sends corrections back through the log.

### Memorizing

<figure>
  <img src="{{ '/assets/shared-memory/loop-memorizing.svg' | relative_url }}" width="560" alt="Memorizing, in the loop: agents write to the event log.">
</figure>

Memories come into Jean from two sources: tasks and explicit `memorize` calls. Work is dispatched to worker agents in a structured way, through tasks, and every task is basically a thread with progress and findings. That makes tasks a natural and easy source to distill general knowledge from: the librarian reads every finished task's thread and keeps what's durable, so a finding reaches the wiki even when no agent memorized it explicitly.

Memorizing is a different animal, because it depends on the agent deciding to do it. That turned out not to be straightforward. At first `memorize` was just an endpoint on the infra, and a skill told agents to call it. Skills are often not loaded, and an endpoint described in Markdown is easy to miss, so I made it a dedicated `memorize` method on the MCP server. A tool shows up in the agent's tool list in every session, and its schema is the instruction.

Even then agents fell back to Claude Code's own memory. Its instructions are in the system prompt of every session, and when there are a lot of instructions in the context, sometimes the instruction that wins is not yours. What fixed it almost completely was a blunt rule in the skill: "in a Jean project you never write to Claude Code's memory".

### Consolidation

<figure>
  <img src="{{ '/assets/shared-memory/loop-consolidation.svg' | relative_url }}" width="560" alt="Consolidation, in the loop: the librarian turns new events into wiki pages.">
</figure>

The core of Karpathy's wiki is letting LLMs manage and organize the knowledge. Because Jean is based on event sourcing there is no special process for reading new memories: start from the last consolidated position and cover all the relevant new events.

Consolidation is done by a headless agent, the librarian, run on a scheduler, usually once a day. Sonnet is used by default. It goes over all new events and looks at the current Markdown library, an index and articles, with instructions on where and when to split articles and how to consolidate. The wiki is committed, so consolidated changes are not lost.

Sounds simple, yet this part also did not work on the first try. A day of events turned out to be a heavy job and it sometimes missed the timeout I had set. The fix was to split the job into more manageable and better-defined steps: a draft, a review and a commit. This seemingly naive change was enough to take the consolidation from 30 minutes to 3.

### Reading

<figure>
  <img src="{{ '/assets/shared-memory/loop-reading.svg' | relative_url }}" width="560" alt="Reading, in the loop: one search over the wiki and what is not consolidated yet.">
</figure>

We have a wiki, consolidated from relevant events. There is a context skill, agents look at the index, they know how to find the relevant article. Problem solved, right?

Not quite. In practice agents, when they are not constrained, access the knowledge in very inconsistent ways. They read a certain page but miss the more relevant one. They look at the summary of a page and decide it's not worth reading the whole article. Sometimes they don't use the wiki at all and grep over the memorize events.

I wanted to make the search more structural, so I added an MCP method for the table of contents: the headers and a short summary of each page. One call to this, another to a specific article, and you're set.

The agents kept grepping the event log instead of using my seemingly very useful memory fetching method. Very disappointing, right? I did a bit of a therapy session. I sat down with an agent I caught red-handed and said, "When you have such a great tool, why do you use grep?" The agent said, "Well, the tool takes several calls, first the table of contents and then the page, and grep is just one call." Additionally, the wiki didn't cover events that weren't consolidated yet, so the agent always decided the wiki wasn't enough.

That was an important understanding in building an end-to-end system. A dedicated one-stop search wasn't just nice to have, it was required to make agents call it consistently. It gave the agents what they asked for: a single tool giving an overview of where to look, not a summary they could skip, not an additional index call. At that point it just clicked and started working consistently.

That's another advantage of one-stop search: it can search both the wiki pages and the recent events that aren't consolidated yet, so nothing memorized falls in between.

Markdown instructions are soft. When you need three of them to make something work, you will feel it breaking quite a lot. In my experience, MCP works better when you need something strict and consistent.

### Handling stale data

<figure>
  <img src="{{ '/assets/shared-memory/loop-stale.svg' | relative_url }}" width="560" alt="Handling stale data, in the loop: the sensei sweeps the wiki and writes corrections to the event log.">
</figure>

So there we go, a working system, right? Still one thing is missing. When the librarian's input is only what's new, it has no authority to understand which data is stale. It is good at finding conflicts and resolving them, but there's always some older data which becomes stale, unused and unneeded over time, and it will stay there if you don't address it explicitly.

So I added another triggered call, this time for the main agent, the orchestrator, the sensei, who has the best context on the project. Once a week it audits the wiki and looks for stale parts. It can't edit the wiki either, no agent can, so for each stale part it memorizes a correction: an ordinary memory that says what is stale, which the librarian applies on the next consolidation.

How much does it matter? I turned the sweep on a work project after it ran for 3.5 months without one. Its first pass over 74 pages flagged 157 corrections, which is about as many as all the corrections in the months before. Almost all of them fix staleness: things that were true once and stop being true. Following the staleness path, 66 pages were updated and the wiki became slightly shorter than before.

### Librarian feedback

<figure>
  <img src="{{ '/assets/shared-memory/loop-questions.svg' | relative_url }}" width="560" alt="Librarian questions, in the loop: the librarian raises questions in the log, the sensei reads them and memorizes answers.">
</figure>

But what if the librarian has questions? The flow is one-directional, so when something doesn't add up, it has to guess. Sometimes it needs feedback to resolve it, and there's a mechanism for that, also based on events. At the end of each consolidation the librarian emits a dedicated event listing what it couldn't resolve, like a contradiction it couldn't settle or a link to a page that no longer exists, and the sensei consumes it.

In practice it's not rare: about 2 in 3 consolidations raise at least one question. The sensei reads them and either settles them or brings them to me. Either way, the answer goes back in as a memory that the next consolidation folds in.

## Results

One of the advantages of using event sourcing is that anything that happened in the past is naturally logged and can be investigated later. I ran an analysis on how the parts of the system work, and some of it was not what I expected.

**Volume.** About 4,500 memories across 6 projects in about 6 months, and alongside them about 700 finished task threads went into consolidation. I was mostly surprised by how often it is used.

**By kind of project.** The personal assistant writes the most: about 17 memories on a day I use it, against about 7 in the work projects and about 5 in my own coding projects. I also talk to it the most, about 55 messages a day, and more of what I say there gets memorized: about 31 memories per 100 messages, against 19-23 in the coding projects. Measured against the work itself, though, the messages and task events in the log together, all three memorize at about the same rate: 12-15 memories per 100 events.

**One in five.** A little under one in five memories opens with CORRECTION, often fixing the memory just before it. I expected most corrections to come from different agents memorizing conflicting things. In practice it's usually one agent that memorized too quickly, before it fully understood, and a few minutes later memorizes the fix. It can't change an event that's already memorized, so that's how a memory gets fixed, and the next consolidation folds in both.

<figure>
  <img src="{{ '/assets/shared-memory/correction-share.svg' | relative_url }}" width="760" alt="Bar chart: corrections as a share of all memories by month, May to October 2026: 21%, 23%, 15%, 16%, 17%, 25%; 18.6% across all months.">
  <figcaption>Event logs of six projects, May to October 2026. April, with 24 memories and no corrections, is left out.</figcaption>
</figure>

**Same share everywhere.** The share doesn't follow the kind of project: about 18-19% in the personal assistant, in my own coding projects and in the work ones.

**Who corrects.** Where the staleness sweep runs,[^1] it made about 4 in 10 of the corrections. Agents made the rest while they worked. The sweep is the sensei auditing the wiki and sending a batch of corrections at once. Month to month its share swung from a quarter to two thirds, highest in October, after two large sweeps[^2].

**What agents correct.** Agents correct two kinds of things. More than half of their corrections fix something the same agent had just memorized.[^3] Those come fast: when such a correction points at the memory it fixes, 80% come within the hour and 99% within the day, before any consolidation, so the mistake never reaches the wiki. About a third fix a page already in the wiki, something the agent ran into while working. That correction is a new memory, and the next consolidation uses it to fix the page. Only about 1% fix another agent's memory.

For that to happen, the memory has to be caught before it's consolidated: once it's in the wiki, the fix goes to the page instead. Still, it was nice to see agents correct each other while a memory was fresh, or while the work it describes was still in progress.

<figure>
  <img src="{{ '/assets/shared-memory/what-agents-correct.svg' | relative_url }}" width="760" alt="Bar chart of 551 corrections agents made while working: 58% fix what the same agent had just memorized, 32% fix a wiki page they name, 9% point at nothing, 1% fix another agent's memory.">
  <figcaption>Event logs of five projects. Sorting rules in note 3.</figcaption>
</figure>

<figure>
  <img src="{{ '/assets/shared-memory/how-soon.svg' | relative_url }}" width="760" alt="Bar chart of 177 corrections that cite the memory they fix, by the time between the two: 80% within the hour, 99% within a day.">
  <figcaption>Event logs of five projects. The sweep’s 16 such corrections are left out: they fix what went stale, not a fresh mistake.</figcaption>
</figure>

**Often it's me.** In about 28% of the agents' corrections, the agent says it's fixing something I caught[^3]. For quick fixes of something just memorized, it's about a third: the agent memorizes, I say it's wrong, and the agent memorizes the fix. Either way, it's still the agent that decides to write the correction.

**Layers.** So the agents' own corrections are mostly in flight: a fresh mistake, fixed by the same agent. About a third fix the wiki itself, wherever the day's work runs into a page that's wrong. Consolidation resolves conflicts between new memories and the pages they land on, which nothing counts as a correction. The sweep is the one layer that looks at every page, including the ones no work touches, and about two thirds of what it corrects has gone stale, while the agents more often fix facts that were never true. Correcting during work is necessary, and it isn't enough on its own.

### Consolidation

**Corrections take effect.** When a correction names a page, the next consolidation changes that page 96-99% of the time[^4]. So a correction memorized during the day reaches the wiki that night, which closes the loop from memorizing to reading.

**Mostly rewriting.** A typical consolidation changes 15-33% of a wiki's pages, and most of those changes rewrite a page that's already there: for every new page, about 8 existing ones get updated, 13-16 in the two oldest wikis. The wiki as a whole keeps growing, but interestingly the average page got longer until August and has been getting shorter since: new pages are now added faster than new lines.

<figure>
  <img src="{{ '/assets/shared-memory/page-length.svg' | relative_url }}" width="760" alt="Line chart of average lines per page at each month's end: 100 in July, 148 in August, 143 in September, 123 in October.">
  <figcaption>Wiki git history, July to October 2026. Index and log pages left out.</figcaption>
</figure>

### Reading

Reads aren't events, so the event log has no record of them. The main source is the agents' session logs, which Claude Code keeps for 30 days by default. I'm adding read logging, so from now on it's recorded. In that month, about 800 searches and about 1,100 page reads, against about 1,250 memories. Workers read about 3.6 times what they write, and the sensei reads about as much as it writes. The difference between the sensei and the workers is interesting. It probably comes with orchestrating: the sensei sees the wider context and memorizes at a higher level, while workers mostly memorize what they ran into on a specific task. The sensei also reads more and writes much more than the workers, which I guess comes with the responsibility.

<figure>
  <img src="{{ '/assets/shared-memory/reads-and-writes.svg' | relative_url }}" width="760" alt="Bar chart of reads and writes by role: the sensei made 1,179 reads and 1,061 writes, 1.1 reads per write; workers made 688 reads and 189 writes, 3.6 reads per write.">
  <figcaption>Agents’ session logs, 23 Sep to 25 Oct. The librarian, which reads pages to write the wiki and never memorizes, is left out.</figcaption>
</figure>

## Closing thoughts

In my experience it works: agents use it, and I don't feel they miss important information. The main lesson for me is that getting agents to remember things is the easy part, and keeping what they remember true is where the real work is. Agents fix mistakes as they work, the librarian asks when something doesn't add up, and a weekly sweep catches what has quietly gone stale.

Jean is open source at [github.com/leonidb/jean](https://github.com/leonidb/jean), and the memory system as built is written up in [docs/wiki.md](https://github.com/leonidb/jean/blob/main/docs/wiki.md).

## Notes

[^1]: The weekly sweep wasn't part of every project from the start. Jean shipped it as a skill that each project's orchestrator had to schedule, and 3 of the 6 did, from May. The sweep numbers come from those three, counted from the day each sweep started. Every active project runs it now.

[^2]: Both large October sweeps were the regular weekly sweep in the personal-assistant project, with 37 and 62 corrections. Almost all fixed something that had gone stale: a decision reversed, an open item since done, a plan that moved on. About one in five instead toned down a rule the wiki stated too strongly.

[^3]: Corrections were sorted by what each one points at: a memory it cites, a wiki page it names, or neither. “Just memorized” also counts corrections that point at nothing when the same agent memorized something in the hour before, so it's likely rather than certain. Credit to me is read from each correction's own wording, and it's a floor, because terminal conversations aren't logged.

[^4]: A correction counts as taking effect when the page it names changed in the consolidation that read it.

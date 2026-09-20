#Ephermal-Kubernetes
The project aims to solve an issue commonly faced by small scale start-ups.

Small scale startups often lack number of servers due to financial constraints.
The developers are forced to test multiple application at the same time on the same server.
Its a time consuming process to setup the environment for the application everytime for a single update or feature test.Its also wasting resources when you leave it as it is when not testing.
people often forget to remove these apps or servers after using it,also team accidentally removing staging servers that testing is not complete yet is common.

The solution is the Ephermal Kubernetes.
After a small change the developer might want to test it.so the developer create a PR to the main branch.
on adding a label to the pr,a github actions pipeline starts.The pipeline uses vcluster to implement ephermal kubernetes and build application automatically.on test completion,the developer remove the label from the PR and the infrastructure is automatically destroyed#.
Which helps in reducing time,effort,errors and cost. 

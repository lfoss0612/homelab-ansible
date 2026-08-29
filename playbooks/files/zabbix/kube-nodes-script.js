var Kube = {
	params: {},
	pods_limit: 1000,

	setParams: function (params) {
		['api_token', 'api_url'].forEach(function (field) {
			if (typeof params !== 'object' || typeof params[field] === 'undefined'
				|| params[field] === '') {
				throw 'Required param is not set: "' + field + '".';
			}
		});
		['endpoint_name', 'pod_filter_labels', 'pod_filter_annotations', 'node_filter_labels', 'node_filter_annotations'].forEach(function (field) {
			if (typeof params !== 'object' || typeof params[field] === 'undefined') {
				throw 'Parameter can be empty but not removed: "' + field + '".';
			}
		});

		Kube.params = params;
		if (typeof Kube.params.api_url === 'string' && !Kube.params.api_url.endsWith('/')) {
			Kube.params.api_url += '/';
		}
	},

	apiRequest: function (query) {
		var request = new HttpRequest(),
			response,
			url = encodeURI(Kube.params.api_url + query);
		if (typeof Kube.params.http_proxy !== 'undefined' && Kube.params.http_proxy !== '') {
			request.setProxy(Kube.params.http_proxy);
		}
		request.addHeader('Content-Type: application/json');
		request.addHeader('Authorization: Bearer ' + Kube.params.api_token);

		if (Kube.params.http_proxy) {
			Zabbix.log(4, '[ Kubernetes ] Using http proxy: ' + Kube.params.http_proxy);
		}
		response = request.get(url);

		Zabbix.log(4, '[ Kubernetes ] Received response with status code ' + request.getStatus() + ': ' + response);

		if (request.getStatus() < 200 || request.getStatus() >= 300) {
			throw 'Request failed with status code ' + request.getStatus() + ': ' + response;
		}

		try {
			response = JSON.parse(response);
		}
		catch (error) {
			throw 'Failed to parse response received from Kubernetes API. Check debug log for more information.';
		}
		return response;
	},

	parseFilters: function (csv) {
		if (!csv)
			return [];

		var filters = [];
		const filterCapture = /([!\w\-\.\/]+)\s*:\s*(.*)/;
		const onComma = /\s*,\s*/;

		csv.split(onComma).forEach(function (kv) {
			var match = kv.match(filterCapture);
			if (!match) {
				Zabbix.log(3, 'Cannot parse filter from: "' + kv + '"');
				return;
			}

			filters.push({ key: match[1], expression: match[2] });
		});

		return filters;
	},

	filter: function (name, data, filters) {
		if (typeof data !== 'object') {
			return true;
		}

		return filters.every(function (filter) {
			const filter_key = filter.key.startsWith('!') ? filter.key.substring(1) : filter.key;

			if (!(filter_key in data)) {
				return true;
			}

			const isExcludingFilter = filter.key.startsWith('!');
			const isMatchForFilter = new RegExp(filter.expression).test(data[filter_key]);

			if ((isExcludingFilter && isMatchForFilter) ||
				(!isExcludingFilter && !isMatchForFilter)) {
				Zabbix.log(4, '[ Kubernetes ] Discarded "' + name + '" by filter "' + filter.key + ': ' + filter.expression + '"');
				return false;
			}

			return true;
		});
	},

	getField: function (data, path) {
		var steps = path.split('.');
		for (var i = 0; i < steps.length; i++) {
			var step = steps[i];
			if (typeof data !== 'object' || typeof data[step] === 'undefined') {
				throw 'Required field was not found: ' + path;
			}

			data = data[step];
		}

		return data;
	},

	getNodes: function () {
		var result = Kube.apiRequest('api/v1/nodes'),
			output = [],
			filterNodeLabels = Kube.parseFilters(Kube.params.node_filter_labels),
			filterNodeAnnotations = Kube.parseFilters(Kube.params.node_filter_annotations);
		if (typeof result !== 'object'
			|| typeof result.items === 'undefined') {
			throw 'Cannot get nodes from Kubernetes API. Check debug log for more information.';
		}

		result.items.forEach(function (filternode) {
			if (Kube.filter(Kube.getField(filternode, 'metadata.name'), Kube.getField(filternode, 'metadata.labels'), filterNodeLabels)
				&& Kube.filter(Kube.getField(filternode, 'metadata.name'), Kube.getField(filternode, 'metadata.annotations'), filterNodeAnnotations)) {
				Zabbix.log(4, '[ Kubernetes ] Filtered node "' + filternode.metadata.name + '"');

				output.push({
					filternode
				});
			}
		});

		return output;
	},

	getPods: function () {
		var result = [],
			continue_token,
			Pods = [];

		while (continue_token !== '') {
			var data = Kube.apiRequest('api/v1/pods?limit=' + Kube.pods_limit
				+ ((typeof continue_token !== 'undefined') ? '&continue=' + continue_token : ''));

			if (typeof data !== 'object'
				|| typeof data.items === 'undefined') {
				throw 'Cannot get pods from Kubernetes API. Check debug log for more information.';
			};

			result.push.apply(result, data.items);
			continue_token = data.metadata.continue || '';
		}
		result.forEach(function (pod) {

			var containers = {
				limits: { cpu: 0, memory: 0 },
				requests: { cpu: 0, memory: 0 },
				restartCount: 0
			},
				containerStatuses = [{ restartCount: 0 }];

			if (typeof pod.status.hostIP === 'object'
				|| typeof pod.status.hostIP === 'undefined') {
				pod.status.hostIP = 'none';
			};

			Kube.getField(pod, 'spec.containers').forEach(function (container) {
				var limits = container.resources.limits,
					requests = container.resources.requests;

				if (typeof limits !== 'undefined') {
					containers.limits.cpu += Fmt.cpuFormat(limits.cpu);
					containers.limits.memory += Fmt.memoryFormat(limits.memory);
				}

				if (typeof requests !== 'undefined') {
					containers.requests.cpu += Fmt.cpuFormat(requests.cpu);
					containers.requests.memory += Fmt.memoryFormat(requests.memory);
				}
			});

			if (typeof pod.status.containerStatuses !== 'object'
				|| typeof pod.status.containerStatuses === 'undefined') {
				pod.status.containerStatuses = containerStatuses;
			};
			pod.status.containerStatuses.forEach(function (container) {
				containers.restartCount += container.restartCount;

			});

			Pods.push({
				'name': pod.metadata.name,
				'nodeIP': pod.status.hostIP,
				'namespace': pod.metadata.namespace,
				'labels': pod.metadata.labels,
				'annotations': pod.metadata.annotations,
				'phase': pod.status.phase,
				'conditions': pod.status.conditions,
				'startTime': pod.status.startTime,
				'containers': containers,
				'hostname': 'none'
			})
		});
		return Pods;
	},

	getEndpointIPs: function () {
		var endpoints = Kube.apiRequest('api/v1/endpoints'),
			endpointIPs = [];
		if (typeof endpoints !== 'object'
			|| typeof endpoints.items === 'undefined') {
			throw 'Cannot get endpoints from Kubernetes API. Check debug log for more information.';
		};

		endpoints.items.forEach(function (ep) {
			if (Kube.getField(ep, 'metadata.name') !== Kube.params.endpoint_name) {
				return;
			}
			if (!Array.isArray(ep.subsets)) {
				return;
			}
			endpointIPs = ep.subsets;

		});
		return endpointIPs;
	}
},

	Fmt = {
		factors: {
			Ki: 1024, K: 1000,
			Mi: 1024 ** 2, M: 1000 ** 2,
			Gi: 1024 ** 3, G: 1000 ** 3,
			Ti: 1024 ** 4, T: 1000 ** 4,
		},

		cpuFormat: function (cpu) {
			if (typeof cpu === 'undefined') {
				return 0;
			}

			if (cpu.indexOf('m') > -1) {
				return parseInt(cpu) / 1000;
			}

			return parseInt(cpu);
		},

		memoryFormat: function (mem) {
			if (typeof mem === 'undefined') {
				return 0;
			}

			var pair,
				factor;

			if (pair = mem.match(/(\d+)(\w*)/)) {
				if (factor = Fmt.factors[pair[2]]) {
					return parseInt(pair[1]) * factor;
				}

				return mem;
			}

			return parseInt(mem);
		}

	}

try {
	Kube.setParams(JSON.parse(value));

	var nodes = Kube.getNodes(),
		pods = Kube.getPods(),
		Pods = [],
		hostname = Kube.params.api_url.match(/https?:\/\/([\w.-]+|\[[a-f0-9:]+\]|[^a-zA-Z:]+)(?::\d+)?/),
		filterPodLabels = Kube.parseFilters(Kube.params.pod_filter_labels),
		filterPodAnnotations = Kube.parseFilters(Kube.params.pod_filter_annotations),
		endpointIPs = Kube.getEndpointIPs();
	if (typeof hostname[1] === 'undefined') {
		Zabbix.log(4, '[ Kubernetes ] Received incorrect Kubernetes API url: ' + api_url + '. Expected format: <scheme>://<host>:<port>');
		throw 'Cannot get hostname from Kubernetes API url. Check debug log for more information.';
	};
	for (idx in nodes) {
		var nodePodsCount = 0,
			endpointpod = [],
			roles = [];
		Object.keys(nodes[idx].filternode.metadata.labels).forEach(function (label) {
			var splitLabel = label.match(/^node-role.kubernetes.io\/([\w\.-]+)/);

			if (splitLabel) {
				roles.push(splitLabel[1]);
			}
		});
		var internalIPs = Kube.getField(nodes[idx].filternode, 'status.addresses').filter(function (addr) {
			return addr.type === 'InternalIP';
		});
		var internalIP = internalIPs.length && internalIPs[0].address;

		var Hostname = Kube.getField(nodes[idx].filternode, 'status.addresses').filter(function (addr) {
			return addr.type === 'Hostname';
		});
		var Hostname = Hostname.length && Hostname[0].address;

		pods.forEach(function (pod) {
			if (pod.nodeIP !== internalIP) {
				return;
			}
			nodePodsCount++;
			pod.hostname = Hostname;
			Pods = pods.filter(function (f) {
				return (f.hostname !== 'none' || f.phase === 'Pending') && (
					Kube.filter(f.name, f.labels, filterPodLabels)
					&& Kube.filter(f.name, f.annotations, filterPodAnnotations)
				);
			}
			)
		});

		endpointIPs.forEach(function (agent) {
			for (k in Kube.getField(agent, 'addresses')) {
				if (Kube.getField(agent.addresses[k], 'ip') === internalIP) {
					endpointpod = Kube.getField(agent.addresses[k], 'targetRef.name')
				}
				for (k in agent.notReadyAddresses) {
					if (agent.notReadyAddresses[k].ip === internalIP) {
						endpointpod = 'notReadyAddresses'
					}
				}

			}
		});

		delete nodes[idx].filternode.metadata.managedFields;
		delete nodes[idx].filternode.status.images;
		nodes[idx].filternode.status.capacity.cpu = Fmt.cpuFormat(nodes[idx].filternode.status.capacity.cpu);
		nodes[idx].filternode.status.capacity.memory = Fmt.memoryFormat(nodes[idx].filternode.status.capacity.memory);
		nodes[idx].filternode.status.allocatable.cpu = Fmt.cpuFormat(nodes[idx].filternode.status.allocatable.cpu);
		nodes[idx].filternode.status.allocatable.memory = Fmt.memoryFormat(nodes[idx].filternode.status.allocatable.memory);
		nodes[idx].filternode.status.podsCount = nodePodsCount;
		nodes[idx].filternode.status.roles = roles.join(', ');
		nodes[idx].filternode.status.agent = endpointpod;
		nodes[idx].filternode.internalIP = internalIP;
		nodes[idx].filternode.clusterhostname = hostname[1];

	}

	return JSON.stringify({ nodes, Pods });
}
catch (error) {
	error += (String(error).endsWith('.')) ? '' : '.';
	Zabbix.log(3, '[ Kubernetes ] ERROR: ' + error);
	return JSON.stringify({ error: error });
}
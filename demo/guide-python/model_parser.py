"""
Demonstration for parsing JSON/UBJSON tree model files
======================================================

See :doc:`/tutorials/saving_model` for details about the model serialization.

"""

import argparse
import json
from dataclasses import dataclass
from enum import IntEnum, unique
from typing import Any, Dict, List, Sequence, Union

import numpy as np

try:
    import ubjson
except ImportError:
    ubjson = None


ParamT = Dict[str, str]


def to_integers(data: Union[bytes, List[int]]) -> List[int]:
    """Convert a sequence of bytes to a list of Python integer"""
    return [v for v in data]


@unique
class SplitType(IntEnum):
    numerical = 0
    categorical = 1


@dataclass
class Node:
    # properties
    left: int
    right: int
    parent: int
    split_idx: int
    split_cond: float
    default_left: bool
    split_type: SplitType
    categories: List[int]
    # statistic
    base_weight: float
    loss_chg: float
    sum_hess: float


class Tree:
    """A tree built by XGBoost."""

    def __init__(self, tree_id: int, nodes: Sequence[Node]) -> None:
        self.tree_id = tree_id
        self.nodes = nodes

    def loss_change(self, node_id: int) -> float:
        """Loss gain of a node."""
        return self.nodes[node_id].loss_chg

    def sum_hessian(self, node_id: int) -> float:
        """Sum Hessian of a node."""
        return self.nodes[node_id].sum_hess

    def base_weight(self, node_id: int) -> float:
        """Base weight of a node."""
        return self.nodes[node_id].base_weight

    def split_index(self, node_id: int) -> int:
        """Split feature index of node."""
        return self.nodes[node_id].split_idx

    def split_condition(self, node_id: int) -> float:
        """Split value of a node."""
        return self.nodes[node_id].split_cond

    def split_categories(self, node_id: int) -> List[int]:
        """Categories in a node."""
        return self.nodes[node_id].categories

    def is_categorical(self, node_id: int) -> bool:
        """Whether a node has categorical split."""
        return self.nodes[node_id].split_type == SplitType.categorical

    def is_numerical(self, node_id: int) -> bool:
        return not self.is_categorical(node_id)

    def parent(self, node_id: int) -> int:
        """Parent ID of a node."""
        return self.nodes[node_id].parent

    def left_child(self, node_id: int) -> int:
        """Left child ID of a node."""
        return self.nodes[node_id].left

    def right_child(self, node_id: int) -> int:
        """Right child ID of a node."""
        return self.nodes[node_id].right

    def is_leaf(self, node_id: int) -> bool:
        """Whether a node is leaf."""
        return self.nodes[node_id].left == -1

    def is_deleted(self, node_id: int) -> bool:
        """Whether a node is deleted."""
        return self.split_index(node_id) == np.iinfo(np.uint32).max

    def __str__(self) -> str:
        stack = [0]
        nodes = []
        while stack:
            node: Dict[str, Union[float, int, List[int]]] = {}
            nid = stack.pop()

            node["node id"] = nid
            node["gain"] = self.loss_change(nid)
            node["cover"] = self.sum_hessian(nid)
            nodes.append(node)

            if not self.is_leaf(nid) and not self.is_deleted(nid):
                left = self.left_child(nid)
                right = self.right_child(nid)
                stack.append(left)
                stack.append(right)
                categories = self.split_categories(nid)
                if categories:
                    assert self.is_categorical(nid)
                    node["categories"] = categories
                else:
                    assert self.is_numerical(nid)
                    node["condition"] = self.split_condition(nid)
            if self.is_leaf(nid):
                node["weight"] = self.split_condition(nid)

        string = "\n".join(map(lambda x: "  " + str(x), nodes))
        return string


class Model:
    """Gradient boosted tree model."""

    def __init__(self, model: dict) -> None:
        """Construct the Model from a JSON object.

        parameters
        ----------
         model : A dictionary loaded by json representing a XGBoost boosted tree model.
        """
        # Basic properties of a model
        self.learner_model_shape: ParamT = model["learner"]["learner_model_param"]
        self.num_output_group = int(self.learner_model_shape["num_class"])
        self.num_feature = int(self.learner_model_shape["num_feature"])
        self.base_score = float(self.learner_model_shape["base_score"])
        # A field encoding which output group a tree belongs
        self.tree_info = model["learner"]["gradient_booster"]["model"]["tree_info"]

        model_shape: ParamT = model["learner"]["gradient_booster"]["model"][
            "gbtree_model_param"
        ]

        # JSON representation of trees
        j_trees = model["learner"]["gradient_booster"]["model"]["trees"]

        # Load the trees
        self.num_trees = int(model_shape["num_trees"])

        trees: List[Tree] = []
        for i in range(self.num_trees):
            tree: Dict[str, Any] = j_trees[i]
            tree_id = int(tree["id"])
            assert tree_id == i, (tree_id, i)
            # - properties
            left_children: List[int] = tree["left_children"]
            right_children: List[int] = tree["right_children"]
            parents: List[int] = tree["parents"]
            split_conditions: List[float] = tree["split_conditions"]
            split_indices: List[int] = tree["split_indices"]
            # when ubjson is used, this is a byte array with each element as uint8
            default_left = to_integers(tree["default_left"])

            # - categorical features
            # when ubjson is used, this is a byte array with each element as uint8
            split_types = to_integers(tree["split_type"])
            # categories for each node is stored in a CSR style storage with segment as
            # the begin ptr and the `categories' as values.
            cat_segments: List[int] = tree["categories_segments"]
            cat_sizes: List[int] = tree["categories_sizes"]
            # node index for categorical nodes
            cat_nodes: List[int] = tree["categories_nodes"]
            assert len(cat_segments) == len(cat_sizes) == len(cat_nodes)
            cats = tree["categories"]
            assert len(left_children) == len(split_types)

            # The storage for categories is only defined for categorical nodes to
            # prevent unnecessary overhead for numerical splits, we track the
            # categorical node that are processed using a counter.
            cat_cnt = 0
            if cat_nodes:
                last_cat_node = cat_nodes[cat_cnt]
            else:
                last_cat_node = -1
            node_categories: List[List[int]] = []
            for node_id in range(len(left_children)):
                if node_id == last_cat_node:
                    beg = cat_segments[cat_cnt]
                    size = cat_sizes[cat_cnt]
                    end = beg + size
                    node_cats = cats[beg:end]
                    # categories are unique for each node
                    assert len(set(node_cats)) == len(node_cats)
                    cat_cnt += 1
                    if cat_cnt == len(cat_nodes):
                        last_cat_node = -1  # continue to process the rest of the nodes
                    else:
                        last_cat_node = cat_nodes[cat_cnt]
                    assert node_cats
                    node_categories.append(node_cats)
                else:
                    # append an empty node, it's either a numerical node or a leaf.
                    node_categories.append([])

            # - stats
            base_weights: List[float] = tree["base_weights"]
            loss_changes: List[float] = tree["loss_changes"]
            sum_hessian: List[float] = tree["sum_hessian"]

            # Construct a list of nodes that have complete information
            nodes: List[Node] = [
                Node(
                    left_children[node_id],
                    right_children[node_id],
                    parents[node_id],
                    split_indices[node_id],
                    split_conditions[node_id],
                    default_left[node_id] == 1,  # to boolean
                    SplitType(split_types[node_id]),
                    node_categories[node_id],
                    base_weights[node_id],
                    loss_changes[node_id],
                    sum_hessian[node_id],
                )
                for node_id in range(len(left_children))
            ]

            pytree = Tree(tree_id, nodes)
            trees.append(pytree)

        self.trees = trees

    def print_model(self) -> None:
        for i, tree in enumerate(self.trees):
            print("\ntree_id:", i)
            print(tree)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Demonstration for loading XGBoost JSON/UBJSON model."
    )
    parser.add_argument(
        "--model", type=str, required=True, help="Path to .json/.ubj model file."
    )
    args = parser.parse_args()
    if args.model.endswith("json"):
        # use json format
        with open(args.model, "r") as fd:
            model = json.load(fd)
    elif args.model.endswith("ubj"):
        if ubjson is None:
            raise ImportError("ubjson is not installed.")
        # use ubjson format
        with open(args.model, "rb") as bfd:
            model = ubjson.load(bfd)
    else:
        raise ValueError(
            "Unexpected file extension. Supported file extension are json and ubj."
        )
    model = Model(model)
    model.print_model()

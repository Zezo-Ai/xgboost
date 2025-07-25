/**
 * Copyright 2023-2025, XGBoost contributors
 */
#include <array>                            // std::array
#include <cstddef>                          // std::size_t
#include <cstdint>                          // std::int32_t
#include <vector>                           // std::vector

#include "../common/linalg_op.h"            // ElementWiseKernel,cbegin,cend
#include "../common/quantile_loss_utils.h"  // QuantileLossParam
#include "../common/stats.h"                // Quantile,WeightedQuantile
#include "adaptive.h"                       // UpdateTreeLeaf
#include "init_estimation.h"                // CheckInitInputs
#include "xgboost/base.h"                   // GradientPair,XGBOOST_DEVICE,bst_target_t
#include "xgboost/data.h"                   // MetaInfo
#include "xgboost/host_device_vector.h"     // HostDeviceVector
#include "xgboost/json.h"                   // Json,String,ToJson,FromJson
#include "xgboost/linalg.h"                 // Tensor,MakeTensorView,MakeVec
#include "xgboost/objective.h"              // ObjFunction

#if defined(XGBOOST_USE_CUDA)

#include "../common/linalg_op.cuh"  // ElementWiseKernel
#include "../common/stats.cuh"      // SegmentedQuantile

#endif                              // defined(XGBOOST_USE_CUDA)

#if defined(XGBOOST_USE_SYCL)
#include "../../plugin/sycl/common/linalg_op.h"  // ElementWiseKernel
#endif

namespace xgboost::obj {
class QuantileRegression : public ObjFunction {
  common::QuantileLossParam param_;
  HostDeviceVector<float> alpha_;

  [[nodiscard]] bst_target_t Targets(MetaInfo const& info) const override {
    auto const& alpha = param_.quantile_alpha.Get();
    CHECK_EQ(alpha.size(), alpha_.Size()) << "The objective is not yet configured.";
    if (info.ShouldHaveLabels()) {
      CHECK_EQ(info.labels.Shape(1), 1)
          << "Multi-target is not yet supported by the quantile loss.";
    }
    CHECK(!alpha.empty());
    // We have some placeholders for multi-target in the quantile loss. But it's not
    // supported as the gbtree doesn't know how to slice the gradient and there's no 3-dim
    // model shape in general.
    auto n_y = std::max(static_cast<std::size_t>(1), info.labels.Shape(1));
    return alpha_.Size() * n_y;
  }

 public:
  void GetGradient(HostDeviceVector<float> const& preds, const MetaInfo& info, std::int32_t iter,
                   linalg::Matrix<GradientPair>* out_gpair) override {
    if (iter == 0) {
      CheckInitInputs(info);
    }
    CHECK_EQ(param_.quantile_alpha.Get().size(), alpha_.Size());

    using SizeT = decltype(info.num_row_);
    SizeT n_targets = this->Targets(info);
    SizeT n_alphas = alpha_.Size();
    CHECK_NE(n_alphas, 0);
    CHECK_GE(n_targets, n_alphas);
    CHECK_EQ(preds.Size(), info.num_row_ * n_targets);

    auto labels = info.labels.View(ctx_->Device());

    out_gpair->SetDevice(ctx_->Device());
    CHECK_EQ(info.labels.Shape(1), 1)
        << "Multi-target for quantile regression is not yet supported.";
    out_gpair->Reshape(info.num_row_, n_targets);
    auto gpair = out_gpair->View(ctx_->Device());

    info.weights_.SetDevice(ctx_->Device());
    common::OptionalWeights weight{ctx_->IsCPU() ? info.weights_.ConstHostSpan()
                                                 : info.weights_.ConstDeviceSpan()};

    preds.SetDevice(ctx_->Device());
    auto predt = linalg::MakeTensorView(ctx_, &preds, info.num_row_, n_targets);

    alpha_.SetDevice(ctx_->Device());
    auto alpha = ctx_->IsCPU() ? alpha_.ConstHostSpan() : alpha_.ConstDeviceSpan();

    linalg::ElementWiseKernel(ctx_, gpair,
                              [=] XGBOOST_DEVICE(std::size_t i, std::size_t j) mutable {
                                // j is the quantile index
                                // 0 is the target index
                                auto d = predt(i, j) - labels(i, 0);
                                auto h = weight[i];
                                if (d >= 0) {
                                  auto g = (1.0f - alpha[j]) * weight[i];
                                  gpair(i, j) = GradientPair{g, h};
                                } else {
                                  auto g = (-alpha[j] * weight[i]);
                                  gpair(i, j) = GradientPair{g, h};
                                }
                              });
  }

  void InitEstimation(MetaInfo const& info, linalg::Vector<float>* base_score) const override {
    CHECK(!alpha_.Empty());

    auto n_targets = this->Targets(info);
    base_score->SetDevice(ctx_->Device());
    base_score->Reshape(n_targets);

    double sw{0};
    if (ctx_->IsCUDA()) {
#if defined(XGBOOST_USE_CUDA)
      alpha_.SetDevice(ctx_->Device());
      auto d_alpha = alpha_.ConstDeviceSpan();
      auto d_labels = info.labels.View(ctx_->Device());
      auto seg_it = dh::MakeTransformIterator<std::size_t>(
          thrust::make_counting_iterator(0ul),
          [=] XGBOOST_DEVICE(std::size_t i) { return i * d_labels.Shape(0); });
      CHECK_EQ(d_labels.Shape(1), 1);
      auto val_it = dh::MakeTransformIterator<float>(thrust::make_counting_iterator(0ul),
                                                     [=] XGBOOST_DEVICE(std::size_t i) {
                                                       auto sample_idx = i % d_labels.Shape(0);
                                                       return d_labels(sample_idx, 0);
                                                     });
      auto n = d_labels.Size() * d_alpha.size();
      CHECK_EQ(base_score->Size(), d_alpha.size());
      if (info.weights_.Empty()) {
        common::SegmentedQuantile(ctx_, d_alpha.data(), seg_it, seg_it + d_alpha.size() + 1, val_it,
                                  val_it + n, base_score->Data());
        sw = info.num_row_;
      } else {
        info.weights_.SetDevice(ctx_->Device());
        auto d_weights = info.weights_.ConstDeviceSpan();
        auto weight_it = dh::MakeTransformIterator<float>(thrust::make_counting_iterator(0ul),
                                                          [=] XGBOOST_DEVICE(std::size_t i) {
                                                            auto sample_idx = i % d_labels.Shape(0);
                                                            return d_weights[sample_idx];
                                                          });
        common::SegmentedWeightedQuantile(ctx_, d_alpha.data(), seg_it, seg_it + d_alpha.size() + 1,
                                          val_it, val_it + n, weight_it, weight_it + n,
                                          base_score->Data());
        sw = dh::Reduce(ctx_->CUDACtx()->CTP(), dh::tcbegin(d_weights), dh::tcend(d_weights), 0.0,
                        thrust::plus<double>{});
      }
#else
      common::AssertGPUSupport();
#endif  // defined(XGBOOST_USE_CUDA)
    } else {
      auto quantiles = base_score->HostView();
      auto h_weights = info.weights_.ConstHostVector();
      if (info.weights_.Empty()) {
        sw = info.num_row_;
      } else {
        sw = std::accumulate(std::cbegin(h_weights), std::cend(h_weights), 0.0);
      }
      for (bst_target_t t{0}; t < n_targets; ++t) {
        auto alpha = param_.quantile_alpha[t];
        auto h_labels = info.labels.HostView();
        if (h_weights.empty()) {
          quantiles(t) =
              common::Quantile(ctx_, alpha, linalg::cbegin(h_labels), linalg::cend(h_labels));
        } else {
          CHECK_EQ(h_weights.size(), h_labels.Size());
          quantiles(t) = common::WeightedQuantile(ctx_, alpha, linalg::cbegin(h_labels),
                                                  linalg::cend(h_labels), std::cbegin(h_weights));
        }
      }
    }

    // For multiple quantiles, we should extend the base score to a vector instead of
    // computing the average. For now, this is a workaround.
    linalg::Vector<float> temp;
    common::Mean(ctx_, *base_score, &temp);
    double meanq = temp(0) * sw;

    std::array<double, 2> dat{meanq, sw};
    auto rc = collective::GlobalSum(ctx_, info, linalg::MakeVec(dat.data(), dat.size()));
    collective::SafeColl(rc);

    std::tie(meanq, sw) = std::tuple_cat(dat);
    meanq /= (sw + kRtEps);
    base_score->Reshape(1);
    base_score->Data()->Fill(meanq);
  }

  void UpdateTreeLeaf(HostDeviceVector<bst_node_t> const& position, MetaInfo const& info,
                      float learning_rate, HostDeviceVector<float> const& prediction,
                      std::int32_t group_idx, RegTree* p_tree) const override {
    auto alpha = param_.quantile_alpha[group_idx];
    ::xgboost::obj::UpdateTreeLeaf(ctx_, position, group_idx, info, learning_rate, prediction,
                                   alpha, p_tree);
  }

  void Configure(Args const& args) override {
    param_.UpdateAllowUnknown(args);
    param_.Validate();
    this->alpha_.HostVector() = param_.quantile_alpha.Get();
  }
  [[nodiscard]] ObjInfo Task() const override { return {ObjInfo::kRegression, true, true}; }
  static char const* Name() { return "reg:quantileerror"; }

  void SaveConfig(Json* p_out) const override {
    auto& out = *p_out;
    out["name"] = String(Name());
    out["quantile_loss_param"] = ToJson(param_);
  }
  void LoadConfig(Json const& in) override {
    CHECK_EQ(get<String const>(in["name"]), Name());
    FromJson(in["quantile_loss_param"], &param_);
    alpha_.HostVector() = param_.quantile_alpha.Get();
  }

  [[nodiscard]] const char* DefaultEvalMetric() const override { return "quantile"; }
  [[nodiscard]] Json DefaultMetricConfig() const override {
    CHECK(param_.GetInitialised());
    Json config{Object{}};
    config["name"] = String{this->DefaultEvalMetric()};
    config["quantile_loss_param"] = ToJson(param_);
    return config;
  }
};

XGBOOST_REGISTER_OBJECTIVE(QuantileRegression, QuantileRegression::Name())
    .describe("Regression with quantile loss.")
    .set_body([]() { return new QuantileRegression(); });

#if defined(XGBOOST_USE_CUDA)
DMLC_REGISTRY_FILE_TAG(quantile_obj_gpu);
#endif  // defined(XGBOOST_USE_CUDA)
}  // namespace xgboost::obj

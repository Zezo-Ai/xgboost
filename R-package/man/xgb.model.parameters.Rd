% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/xgb.Booster.R
\name{xgb.model.parameters<-}
\alias{xgb.model.parameters<-}
\title{Accessors for model parameters}
\usage{
xgb.model.parameters(object) <- value
}
\arguments{
\item{object}{Object of class \code{xgb.Booster}. \strong{Will be modified in-place}.}

\item{value}{A list (or an object coercible to a list) with the names of parameters to set
and the elements corresponding to parameter values.}
}
\value{
The same booster \code{object}, which gets modified in-place.
}
\description{
Only the setter for XGBoost parameters is currently implemented.
}
\details{
Just like \code{\link[=xgb.attr]{xgb.attr()}}, this function will make in-place modifications
on the booster object which do not follow typical R assignment semantics - that is,
all references to the same booster will also be updated, unlike assingment of R
attributes which follow copy-on-write semantics.

See \code{\link[=xgb.copy.Booster]{xgb.copy.Booster()}} for an example of this behavior.

Be aware that setting parameters of a fitted booster related to training continuation / updates
will reset its number of rounds indicator to zero.
}
\examples{
data(agaricus.train, package = "xgboost")

train <- agaricus.train

bst <- xgb.train(
  data = xgb.DMatrix(train$data, label = train$label, nthread = 1),
  nrounds = 2,
  params = xgb.params(
    max_depth = 2,
    learning_rate = 1,
    nthread = 2,
    objective = "binary:logistic"
  )
)

xgb.model.parameters(bst) <- list(learning_rate = 0.1)

}

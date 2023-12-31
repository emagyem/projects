library(tidyverse)
library(caret) #createDataPartition
library(doParallel)
library(ConfusionTableR)
library(pROC)
library(DMwR2) #SMOTE funciton

##Seed
set.seed(123)

##Data
stroke <- read.csv("C:/Users/13035/OneDrive/Desktop/Datasets/brain_stroke_100.csv") %>%
  as.data.frame() %>%
  mutate(stroke = ifelse(stroke == 1, "stroke", "no_stroke"),
         stroke = factor(stroke, levels = c("stroke", "no_stroke"))) #modify target variable to be factor

stroke[sapply(stroke, is.character)] <- lapply(stroke[sapply(stroke, is.character)], 
                                               as.factor) #transform chr cols to factors



#split data
set.seed(123)
split_index <- createDataPartition(stroke$stroke,
                                   p = .3, 
                                   list = FALSE,
                                   times = 1) #divide data into 30% test and 70% train

rf_train <- stroke[-split_index,]
rf_test <- stroke[split_index,]

#run random forest with caret
cv_folds <- createFolds(y = rf_train$stroke, 
                        k = 10, 
                        returnTrain = TRUE)

trControl <- trainControl(method = "cv", 
                          number = 10,
                          p = 0.7,
                          search = "grid",
                          classProbs = TRUE,
                          savePredictions = "final",
                          index = cv_folds,
                          sampling = "up",
                          summaryFunction = twoClassSummary)

tuneGrid <- expand.grid(.mtry = c(1: 11))

ntrees <- c(500, 700, 1000)
nodesize <- c(1,5)

params <- expand.grid(ntrees = ntrees,
                      nodesize = nodesize)

store_maxnode <- vector("list", nrow(params))

pb = txtProgressBar(min = 0, 
                    max = nrow(params), 
                    style = 3,
                    width = 50,
                    char = "=")

cl <- makePSOCKcluster(6)
registerDoParallel(cl)

for(i in 1:nrow(params)){
  
  nodesize <- params[i,2]
  ntree <- params[i,1]
  set.seed(123)
  rf_model <- train(stroke~.,
                    data = rf_train,
                    method = "rf",
                    metric = "ROC",
                    tuneGrid = tuneGrid,
                    trControl = trControl,
                    importance = TRUE,
                    nodesize = nodesize,
                    ntree = ntree)
  store_maxnode[[i]] <- rf_model
  
  setTxtProgressBar(pb,i)
}

close(pb)
stopCluster(cl)

#clean up parallel computing
unregister_dopar <- function() {
  env <- foreach:::.foreachGlobals
  rm(list=ls(name=env), pos=env)
}
unregister_dopar()

names(store_maxnode) <- paste("ntrees:", params$ntrees,
                              "nodesize:", params$nodesize)

results_mtry <- resamples(store_maxnode)
summary(results_mtry)

#make data frame of different models results
result_df_list <- lapply(store_maxnode, function(x) x$results)
rep_names <- names(result_df_list)
result_df_list <- map2(result_df_list, 
                       rep_names, 
                       function(x,y) cbind(x, rep(y, nrow(x))))
combined_results <- do.call("rbind", result_df_list) %>%
  rename("ntrees_nodesize" = "rep(y, nrow(x))")

maxroc <- combined_results %>%
  group_by(ntrees_nodesize) %>%
  summarise(maxroc = max(ROC))

minmtry_maxroc <- combined_results %>%
  filter(ROC %in% maxroc$maxroc &
           ntrees_nodesize %in% maxroc$ntrees_nodesize) %>%
  select(mtry, ROC) %>%
  arrange(desc(ROC))

knitr::kable(minmtry_maxroc)

svg("figures/rf_tuning_plot.svg", height = 5, width = 5)
combined_results %>%
  ggplot(aes(x = mtry, y = ROC, color = ntrees_nodesize)) +
  geom_point() +
  geom_line() +
  theme_classic()
dev.off()

#train tuned model
tuneGrid <- expand.grid(.mtry = 6)

trControl <- trainControl(method = "cv", 
                          p = 0.7,
                          number = 10,
                          search = "grid",
                          classProbs = TRUE,
                          savePredictions = "final",
                          sampling = "up")

final_model <- train(stroke~.,
                     data = rf_train,
                     method = "rf",
                     metric = "Accuracy",
                     trControl = trControl,
                     tuneGrid = tuneGrid,
                     importance = TRUE,
                     nodesize = 1,
                     ntree = 1000)

#function to fit models with different samplings
fit_models_sampling <- function(samp){
  
  
  train(stroke~.,
        data = rf_train,
        method = "rf",
        metric = "Accuracy",
        trControl = trainControl(method = "cv", 
                                 p = 0.7,
                                 number = 10,
                                 search = "grid",
                                 classProbs = TRUE,
                                 savePredictions = "final",
                                 sampling = samp),
        tuneGrid = expand.grid(.mtry = 6),
        importance = TRUE,
        nodesize = 1,
        ntree = 1000)
  
}

sampling_models <- map(c("up", "down", "smote"), fit_models_sampling)
names(sampling_models) <- c("up", "down", "smote")



#Predict 
pred_list <- map(sampling_models, ~predict(.x, rf_test, type = "prob"))
names(pred_list) <- c("up", "down", "smote")

#ROC
roc_list <- map(pred_list, ~roc(rf_test$stroke, .x[,"stroke"]))
names(roc_list) <- c("up", "down", "smote")

#AUC
auc_data <- roc_list %>%
  map(~tibble(AUC = .x$auc)) %>%
  bind_rows(.id = "name") 

#lables for plot
auc_data_labels <- auc_data %>%
  mutate(label_long = paste0(name, ", AUC = ", paste(round(AUC,3))),
         label_AUC = paste0("AUC = ", paste(round(AUC, 3))))

#AUC plot
svg("figures/final_rf_auc.svg")
ggroc(roc_list) +
  scale_color_discrete(labels = auc_data_labels$label_long) +
  theme_classic() +
  labs(color = "Random Forest Re-sampling Type")
dev.off()

#best model upsampled
pred <- predict(sampling_models[["up"]], rf_test)
confusionMatrix(pred, reference = rf_test$stroke)


#produce figure of confusion matrix for best model (upsampled)
rf_cm <- binary_class_cm(pred, rf_test$stroke)
svg("figures/final_rf_confusion_matrix.svg", )
binary_visualiseR(train_labels = pred,
                  truth_labels = rf_test$stroke,
                  class_label1 = "Stroke",
                  class_label2 = "No Stroke",
                  custom_title = "Final Random Forest Confusion Matrix")
dev.off()
